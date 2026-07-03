/////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Tencent is pleased to support the open source community by making libpag available.
//
//  Copyright (C) 2021 Tencent. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  unless required by applicable law or agreed to in writing, software distributed under the
//  license is distributed on an "as is" basis, without warranties or conditions of any kind,
//  either express or implied. see the license for the specific language governing permissions
//  and limitations under the license.
//
/////////////////////////////////////////////////////////////////////////////////////////////////

#import "PAG.h"
#import "platform/cocoa/private/PAGImpl.h"
#import <mach/mach_time.h>
#import <sys/utsname.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

static NSInteger const PAGPerfTraceSchemaVersion = 1;
static NSString* const PAGPerfTraceQueueLabel = @"com.tencent.pag.perf.trace";
static NSString* const PAGPerfTraceRunEnv = @"PAG_PERF_TRACE";
static NSString* const PAGPerfBackendEnv = @"PAG_PERF_BACKEND";
static NSString* const PAGPerfBuildIDEnv = @"PAG_PERF_BUILD_ID";

static BOOL PAGPerfTraceEnabled = NO;
static BOOL PAGPerfTraceClosed = NO;
static NSString* PAGPerfTraceScenario = nil;
static NSString* PAGPerfTraceSessionID = nil;
static NSString* PAGPerfTraceCurrentLogPath = nil;
static NSFileHandle* PAGPerfTraceHandle = nil;
static dispatch_queue_t PAGPerfTraceQueue = nil;
static NSMutableData* PAGPerfTraceBuffer = nil;
static NSInteger PAGPerfTracePendingLines = 0;

@implementation PAG

+ (NSString*)SDKVersion {
  return [PAGImpl SDKVersion];
}

@end

static uint64_t PAGPerfTraceNowInMicroseconds() {
  static mach_timebase_info_data_t timebase = {0, 0};
  if (timebase.denom == 0) {
    mach_timebase_info(&timebase);
  }
  uint64_t now = mach_absolute_time();
  return now * timebase.numer / timebase.denom / 1000;
}

static NSString* PAGPerfTraceEnvironmentValue(NSString* key) {
  return [[[NSProcessInfo processInfo] environment] objectForKey:key];
}

static BOOL PAGPerfTraceIsTruthy(NSString* value) {
  if (value.length == 0) {
    return NO;
  }
  NSString* lower = [value lowercaseString];
  return [lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] ||
         [lower isEqualToString:@"yes"] || [lower isEqualToString:@"on"];
}

static NSString* PAGPerfTraceDeviceModel() {
  struct utsname systemInfo = {0};
  uname(&systemInfo);
  return [NSString stringWithUTF8String:systemInfo.machine];
}

static NSString* PAGPerfTraceThermalStateName() {
#if TARGET_OS_IPHONE
  if (@available(iOS 11.0, *)) {
    switch ([NSProcessInfo processInfo].thermalState) {
      case NSProcessInfoThermalStateNominal:
        return @"nominal";
      case NSProcessInfoThermalStateFair:
        return @"fair";
      case NSProcessInfoThermalStateSerious:
        return @"serious";
      case NSProcessInfoThermalStateCritical:
        return @"critical";
    }
  }
#endif
  return @"unknown";
}

static NSString* PAGPerfTraceSystemVersion() {
#if TARGET_OS_IPHONE
  return [[UIDevice currentDevice] systemVersion];
#else
  return [[NSProcessInfo processInfo] operatingSystemVersionString];
#endif
}

static CGFloat PAGPerfTraceScreenScale() {
#if TARGET_OS_IPHONE
  return [UIScreen mainScreen].scale;
#else
  return 1.0;
#endif
}

static NSString* PAGPerfTraceTimestampString() {
  NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.dateFormat = @"yyyyMMdd_HHmmss";
  NSString* value = [formatter stringFromDate:[NSDate date]];
  [formatter release];
  return value;
}

static void PAGPerfTraceEnsureQueue() {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    PAGPerfTraceQueue =
        dispatch_queue_create([PAGPerfTraceQueueLabel UTF8String], DISPATCH_QUEUE_SERIAL);
    PAGPerfTraceBuffer = [[NSMutableData alloc] initWithCapacity:256 * 1024];
  });
}

static NSString* PAGPerfTraceLogsDirectoryPath() {
  NSArray<NSString*>* directories =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString* documents = directories.count > 0 ? directories.firstObject : NSTemporaryDirectory();
  NSString* directory = [documents stringByAppendingPathComponent:@"PAGPerf"];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return directory;
}

static void PAGPerfTraceAddFields(NSMutableDictionary* target, NSDictionary* fields) {
  for (id key in fields) {
    id value = [fields objectForKey:key];
    if (![key isKindOfClass:[NSString class]] || value == nil || value == [NSNull null]) {
      continue;
    }
    [target setObject:value forKey:key];
  }
}

static NSData* PAGPerfTraceJSONLineData(NSDictionary* fields) {
  if (![NSJSONSerialization isValidJSONObject:fields]) {
    return nil;
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:fields options:0 error:nil];
  if (data.length == 0) {
    return nil;
  }
  NSMutableData* line = [NSMutableData dataWithData:data];
  const char newline = '\n';
  [line appendBytes:&newline length:1];
  return line;
}

static void PAGPerfTraceWriteBufferOnQueue(BOOL synchronize) {
  if (PAGPerfTraceHandle == nil || PAGPerfTraceBuffer.length == 0) {
    return;
  }
  @try {
    [PAGPerfTraceHandle writeData:PAGPerfTraceBuffer];
    if (synchronize) {
      [PAGPerfTraceHandle synchronizeFile];
    }
  } @catch (NSException* exception) {
    NSLog(@"[PAGPerfTrace] write failed: %@", exception);
  }
  [PAGPerfTraceBuffer setLength:0];
  PAGPerfTracePendingLines = 0;
}

static void PAGPerfTraceAppendLineData(NSData* data) {
  if (data.length == 0) {
    return;
  }
  PAGPerfTraceEnsureQueue();
  dispatch_async(PAGPerfTraceQueue, ^{
    if (!PAGPerfTraceEnabled || PAGPerfTraceHandle == nil) {
      return;
    }
    [PAGPerfTraceBuffer appendData:data];
    PAGPerfTracePendingLines++;
    if (PAGPerfTracePendingLines >= 120 || PAGPerfTraceBuffer.length >= 256 * 1024) {
      PAGPerfTraceWriteBufferOnQueue(NO);
    }
  });
}

static void PAGPerfTraceAppendEvent(NSString* event, NSDictionary* fields) {
  if (!PAGPerfTraceEnabled || PAGPerfTraceClosed || event.length == 0) {
    return;
  }
  NSMutableDictionary* line = [NSMutableDictionary dictionary];
  [line setObject:@(PAGPerfTraceSchemaVersion) forKey:@"schema_version"];
  [line setObject:event forKey:@"event"];
  [line setObject:[PAGPerfTrace Backend] forKey:@"backend"];
  [line setObject:[PAGPerfTrace BuildID] forKey:@"build_id"];
  [line setObject:PAGPerfTraceScenario != nil ? PAGPerfTraceScenario : @"" forKey:@"scenario"];
  [line setObject:PAGPerfTraceSessionID != nil ? PAGPerfTraceSessionID : @"" forKey:@"session_id"];
  [line setObject:@(PAGPerfTraceNowInMicroseconds()) forKey:@"timestamp_us"];
  if (fields != nil) {
    PAGPerfTraceAddFields(line, fields);
  }
  PAGPerfTraceAppendLineData(PAGPerfTraceJSONLineData(line));
}

static BOOL PAGPerfTraceIsPerfLogPath(NSString* path) {
  NSString* name = [path lastPathComponent];
  return [name hasPrefix:@"pag_perf_"] && [[name pathExtension] isEqualToString:@"jsonl"];
}

@implementation PAGPerfTrace

+ (void)StartSessionWithScenario:(NSString*)scenario {
  PAGPerfTraceEnsureQueue();
  @synchronized(self) {
    PAGPerfTraceEnabled = YES;
    PAGPerfTraceClosed = NO;
    if (PAGPerfTraceHandle != nil) {
      return;
    }
    [PAGPerfTraceScenario release];
    PAGPerfTraceScenario = [(scenario.length > 0 ? scenario : @"pag_viewer") copy];
    [PAGPerfTraceSessionID release];
    PAGPerfTraceSessionID = [[[NSUUID UUID] UUIDString] copy];
    NSString* fileName = [NSString
        stringWithFormat:@"pag_perf_%@_%@_%@_%@.jsonl", [self Backend], PAGPerfTraceScenario,
                         PAGPerfTraceDeviceModel(), PAGPerfTraceTimestampString()];
    [PAGPerfTraceCurrentLogPath release];
    PAGPerfTraceCurrentLogPath =
        [[PAGPerfTraceLogsDirectoryPath() stringByAppendingPathComponent:fileName] copy];
    [[NSFileManager defaultManager] createFileAtPath:PAGPerfTraceCurrentLogPath
                                            contents:nil
                                          attributes:nil];
    PAGPerfTraceHandle =
        [[NSFileHandle fileHandleForWritingAtPath:PAGPerfTraceCurrentLogPath] retain];
  }
  [self LogEvent:@"start"
          fields:@{
            @"device" : PAGPerfTraceDeviceModel(),
            @"system" : [[NSProcessInfo processInfo] operatingSystemVersionString],
            @"system_version" : PAGPerfTraceSystemVersion(),
            @"screen_scale" : @(PAGPerfTraceScreenScale()),
            @"thermal_state" : PAGPerfTraceThermalStateName(),
            @"log_path" : PAGPerfTraceCurrentLogPath != nil ? PAGPerfTraceCurrentLogPath : @"",
          }];
  [self Flush];
}

+ (void)SetEnabled:(BOOL)enabled {
  if (enabled) {
    [self StartSessionWithScenario:@"pag_viewer"];
    return;
  }
  @synchronized(self) {
    PAGPerfTraceEnabled = NO;
  }
}

+ (BOOL)Enabled {
  return PAGPerfTraceEnabled && !PAGPerfTraceClosed;
}

+ (void)LogEvent:(NSString*)event fields:(NSDictionary*)fields {
  if (![self Enabled]) {
    return;
  }
  if (PAGPerfTraceHandle == nil) {
    [self StartSessionWithScenario:@"pag_viewer"];
  }
  PAGPerfTraceAppendEvent(event, fields);
}

+ (void)Flush {
  PAGPerfTraceEnsureQueue();
  dispatch_sync(PAGPerfTraceQueue, ^{
    PAGPerfTraceWriteBufferOnQueue(YES);
  });
}

+ (void)Close {
  if (PAGPerfTraceClosed) {
    return;
  }
  PAGPerfTraceAppendEvent(
      @"done", @{@"log_path" : PAGPerfTraceCurrentLogPath != nil ? PAGPerfTraceCurrentLogPath : @""});
  PAGPerfTraceEnsureQueue();
  dispatch_sync(PAGPerfTraceQueue, ^{
    PAGPerfTraceWriteBufferOnQueue(YES);
    if (PAGPerfTraceHandle != nil) {
      [PAGPerfTraceHandle closeFile];
      [PAGPerfTraceHandle release];
      PAGPerfTraceHandle = nil;
    }
  });
  @synchronized(self) {
    PAGPerfTraceClosed = YES;
    PAGPerfTraceEnabled = NO;
  }
}

+ (NSString*)CurrentLogPath {
  return PAGPerfTraceCurrentLogPath == nil ? nil : [[PAGPerfTraceCurrentLogPath retain] autorelease];
}

+ (NSString*)LogsDirectory {
  return PAGPerfTraceLogsDirectoryPath();
}

+ (NSArray<NSString*>*)LogFiles {
  NSString* directory = PAGPerfTraceLogsDirectoryPath();
  NSArray<NSString*>* names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory
                                                                                  error:nil];
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  for (NSString* name in names) {
    NSString* path = [directory stringByAppendingPathComponent:name];
    if (PAGPerfTraceIsPerfLogPath(path)) {
      [paths addObject:path];
    }
  }
  [paths sortUsingComparator:^NSComparisonResult(NSString* left, NSString* right) {
    NSDictionary* leftAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:left
                                                                                    error:nil];
    NSDictionary* rightAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:right
                                                                                     error:nil];
    NSDate* leftDate = [leftAttributes fileModificationDate];
    NSDate* rightDate = [rightAttributes fileModificationDate];
    leftDate = leftDate != nil ? leftDate : [NSDate distantPast];
    rightDate = rightDate != nil ? rightDate : [NSDate distantPast];
    return [rightDate compare:leftDate];
  }];
  return paths;
}

+ (NSUInteger)RemoveLogFilesSkippingCurrent:(BOOL)skipCurrent {
  [self Flush];
  NSString* currentPath = [self CurrentLogPath];
  BOOL shouldSkipCurrent = skipCurrent && PAGPerfTraceEnabled && !PAGPerfTraceClosed;
  NSUInteger removed = 0;
  for (NSString* path in [self LogFiles]) {
    if (shouldSkipCurrent && currentPath.length > 0 && [path isEqualToString:currentPath]) {
      continue;
    }
    if ([[NSFileManager defaultManager] removeItemAtPath:path error:nil]) {
      removed++;
    }
  }
  return removed;
}

+ (NSString*)Backend {
  NSString* value = PAGPerfTraceEnvironmentValue(PAGPerfBackendEnv);
  return value.length > 0 ? value : @"opengl";
}

+ (NSString*)BuildID {
  NSString* value = PAGPerfTraceEnvironmentValue(PAGPerfBuildIDEnv);
  return value.length > 0 ? value : @"local";
}

+ (void)load {
  NSString* value = PAGPerfTraceEnvironmentValue(PAGPerfTraceRunEnv);
  if (PAGPerfTraceIsTruthy(value)) {
    [self StartSessionWithScenario:@"pag_viewer"];
  }
}

@end
