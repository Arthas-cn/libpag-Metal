/////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Tencent is pleased to support the open source community by making libpag available.
//
//  Copyright (C) 2026 Tencent. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//
/////////////////////////////////////////////////////////////////////////////////////////////////

#import "PAGPerfRunner.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <libpag/PAG.h>
#import <libpag/PAGPlayer.h>
#import <libpag/PAGSurface.h>
#import <libpag/PAGView.h>
#import <mach/mach_time.h>
#import <sys/utsname.h>
#include <cmath>

namespace {
NSInteger const kPerfSchemaVersion = 2;
NSString* const kPerfRunEnv = @"PAG_PERF_RUN";
NSString* const kPerfCasesEnv = @"PAG_PERF_CASES";
NSString* const kPerfRunsEnv = @"PAG_PERF_RUNS";
NSString* const kPerfWarmupsEnv = @"PAG_PERF_WARMUPS";
NSString* const kPerfMaxFramesEnv = @"PAG_PERF_MAX_FRAMES";
NSString* const kPerfOutputEnv = @"PAG_PERF_OUTPUT";
NSString* const kPerfFrameBatchEnv = @"PAG_PERF_FRAME_BATCH";
NSString* const kPerfTargetEnv = @"PAG_PERF_TARGET";
NSString* const kPerfStepDelayEnv = @"PAG_PERF_STEP_DELAY_MS";
NSString* const kPerfLogFlushEnv = @"PAG_PERF_LOG_FLUSH_FRAMES";
NSInteger const kMaxSurfaceWaitAttempts = 3000;
NSInteger const kDefaultOffscreenFrameBatch = 30;
NSInteger const kDefaultLayerFrameBatch = 1;
NSInteger const kDefaultLogFlushFrames = 120;

uint64_t NowInMicroseconds() {
  static mach_timebase_info_data_t timebase = {0, 0};
  if (timebase.denom == 0) {
    mach_timebase_info(&timebase);
  }
  uint64_t now = mach_absolute_time();
  return now * timebase.numer / timebase.denom / 1000;
}

NSString* EnvironmentValue(NSString* key) {
  return [[[NSProcessInfo processInfo] environment] objectForKey:key];
}

NSString* ArgumentValue(NSString* key) {
  NSArray<NSString*>* arguments = [[NSProcessInfo processInfo] arguments];
  NSString* flag = [@"-" stringByAppendingString:key];
  NSUInteger index = [arguments indexOfObject:flag];
  if (index == NSNotFound || index + 1 >= arguments.count) {
    return nil;
  }
  return [arguments objectAtIndex:index + 1];
}

NSString* ConfigValue(NSString* key, NSString* defaultValue) {
  NSString* argumentValue = ArgumentValue(key);
  if (argumentValue.length > 0) {
    return argumentValue;
  }
  NSString* environmentValue = EnvironmentValue([key uppercaseString]);
  return environmentValue.length > 0 ? environmentValue : defaultValue;
}

BOOL IsTruthy(NSString* value) {
  if (value.length == 0) {
    return NO;
  }
  NSString* lower = [value lowercaseString];
  return [lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] ||
         [lower isEqualToString:@"yes"] || [lower isEqualToString:@"on"];
}

NSInteger IntegerConfig(NSString* key, NSInteger defaultValue) {
  NSString* value = ConfigValue(key, nil);
  return value.length > 0 ? [value integerValue] : defaultValue;
}

NSString* JSONString(NSString* value) {
  if (value == nil) {
    return @"\"\"";
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:@[ value ] options:0 error:nil];
  NSString* arrayString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return [arrayString substringWithRange:NSMakeRange(1, arrayString.length - 2)];
}

NSString* DeviceModel() {
  struct utsname systemInfo = {0};
  uname(&systemInfo);
  return [NSString stringWithUTF8String:systemInfo.machine];
}

NSString* ThermalStateName(NSProcessInfoThermalState state) {
  switch (state) {
    case NSProcessInfoThermalStateNominal:
      return @"nominal";
    case NSProcessInfoThermalStateFair:
      return @"fair";
    case NSProcessInfoThermalStateSerious:
      return @"serious";
    case NSProcessInfoThermalStateCritical:
      return @"critical";
  }
  return @"unknown";
}

NSString* DefaultGPUName() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  return device.name.length > 0 ? device.name : @"unknown";
}

NSArray<NSString*>* DefaultCases() {
  return @[
    @"alpha.pag",
    @"DropShadow.pag",
    @"guide_hand_drag.pag",
    @"particle_video.pag",
    @"RootLayerBitmap.pag",
    @"RootLayerVideo.pag",
    @"TextAnimatorX7.pag",
    @"transitions.pag",
    @"motiontile1.pag",
    @"replacement.pag",
  ];
}

NSArray<NSString*>* CaseList() {
  NSString* cases = ConfigValue(kPerfCasesEnv, nil);
  if (cases.length == 0) {
    return DefaultCases();
  }
  NSMutableArray<NSString*>* result = [NSMutableArray array];
  for (NSString* item in [cases componentsSeparatedByString:@","]) {
    NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 0) {
      [result addObject:trimmed];
    }
  }
  return result.count > 0 ? result : DefaultCases();
}

NSString* BundlePathForCase(NSString* caseName) {
  NSString* extension = [caseName pathExtension];
  NSString* resource = extension.length > 0 ? [caseName stringByDeletingPathExtension] : caseName;
  NSString* type = extension.length > 0 ? extension : @"pag";
  return [[NSBundle mainBundle] pathForResource:resource ofType:type];
}

NSInteger FrameCountForFile(PAGFile* file, NSInteger maxFrames) {
  double seconds = static_cast<double>([file duration]) / 1000000.0;
  NSInteger frames = static_cast<NSInteger>(ceil(seconds * [file frameRate]));
  if (frames < 1) {
    frames = 1;
  }
  if (maxFrames > 0 && frames > maxFrames) {
    return maxFrames;
  }
  return frames;
}

NSString* PerfBackend() {
  return [PAGPerfTrace Backend];
}

NSString* PerfBuildID() {
  return [PAGPerfTrace BuildID];
}

NSString* RenderTargetName() {
  NSString* target = ConfigValue(kPerfTargetEnv, @"offscreen");
  NSString* lower = [target lowercaseString];
  if ([lower isEqualToString:@"layer"] || [lower isEqualToString:@"pag_view"] ||
      [lower isEqualToString:@"view"]) {
    return @"layer";
  }
  return @"offscreen";
}

BOOL UsesLayerTarget() {
  return [RenderTargetName() isEqualToString:@"layer"];
}

NSString* OutputPath() {
  NSString* configuredPath = ConfigValue(kPerfOutputEnv, nil);
  if (configuredPath.length > 0) {
    return configuredPath;
  }
  NSArray<NSString*>* directories =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString* documents = directories.count > 0 ? directories.firstObject : NSTemporaryDirectory();
  NSString* outputDirectory = [documents stringByAppendingPathComponent:@"PAGPerf"];
  [[NSFileManager defaultManager] createDirectoryAtPath:outputDirectory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.dateFormat = @"yyyyMMdd_HHmmss";
  NSString* target = RenderTargetName();
  NSString* fileName = [NSString stringWithFormat:@"pag_perf_%@_%@_%@_%@.jsonl", PerfBackend(),
                                                  target, DeviceModel(),
                                                  [formatter stringFromDate:[NSDate date]]];
  return [outputDirectory stringByAppendingPathComponent:fileName];
}

struct FramePerfMetrics {
  BOOL changed;
  uint64_t flushUs;
  int64_t prepareUs;
  int64_t drawUs;
  int64_t imageDecodeUs;
  int64_t graphicsMemoryBytes;
};

FramePerfMetrics SamplePlayerFrame(PAGPlayer* player, double progress) {
  [player setProgress:progress];
  uint64_t start = NowInMicroseconds();
  BOOL changed = [player flush];
  uint64_t flushUs = NowInMicroseconds() - start;
  int64_t prepareUs = [player renderingTime];
  int64_t drawUs = [player presentingTime];
  int64_t imageDecodeUs = [player imageDecodingTime];
  int64_t graphicsMemoryBytes = [player graphicsMemory];
  if (!changed) {
    prepareUs = -1;
    drawUs = -1;
    imageDecodeUs = -1;
    graphicsMemoryBytes = -1;
  }
  return {changed, flushUs, prepareUs, drawUs, imageDecodeUs, graphicsMemoryBytes};
}

FramePerfMetrics SampleViewFrame(PAGView* pagView, double progress) {
  uint64_t start = NowInMicroseconds();
  BOOL changed = [pagView flushAtProgress:progress];
  uint64_t flushUs = NowInMicroseconds() - start;
  int64_t prepareUs = [pagView renderingTime];
  int64_t drawUs = [pagView presentingTime];
  int64_t imageDecodeUs = [pagView imageDecodingTime];
  int64_t graphicsMemoryBytes = [pagView graphicsMemory];
  if (!changed) {
    prepareUs = -1;
    drawUs = -1;
    imageDecodeUs = -1;
    graphicsMemoryBytes = -1;
  }
  return {changed, flushUs, prepareUs, drawUs, imageDecodeUs, graphicsMemoryBytes};
}
}  // namespace

@interface PAGPerfLogWriter : NSObject

- (instancetype)initWithPath:(NSString*)path;
- (void)appendLine:(NSString*)line;
- (void)flushToDisk:(BOOL)synchronize;
- (void)closeAndSync;

@end

@interface PAGPerfLogWriter ()

@property(nonatomic, strong) NSString* path;
@property(nonatomic, strong) NSFileHandle* handle;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableData* buffer;
@property(nonatomic, assign) NSInteger pendingLines;

@end

@implementation PAGPerfLogWriter

- (instancetype)initWithPath:(NSString*)path {
  self = [super init];
  if (self) {
    _path = [path copy];
    _queue = dispatch_queue_create("com.tencent.pag.perf.log", DISPATCH_QUEUE_SERIAL);
    _buffer = [NSMutableData dataWithCapacity:256 * 1024];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    _handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (_handle == nil) {
      return nil;
    }
  }
  return self;
}

- (void)appendDataOnQueue:(NSData*)data {
  if (self.handle == nil || data.length == 0) {
    return;
  }
  [self.buffer appendData:data];
  self.pendingLines++;
}

- (void)writeBufferToFile:(BOOL)synchronize {
  if (self.handle == nil || self.buffer.length == 0) {
    return;
  }
  @try {
    [self.handle writeData:self.buffer];
    if (synchronize) {
      [self.handle synchronizeFile];
    }
  } @catch (NSException* exception) {
    NSLog(@"[PAGPerf] log write failed: %@", exception);
  }
  [self.buffer setLength:0];
  self.pendingLines = 0;
}

- (void)appendLine:(NSString*)line {
  if (line.length == 0) {
    return;
  }
  NSString* output = [line stringByAppendingString:@"\n"];
  NSData* data = [output dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_async(self.queue, ^{
    [self appendDataOnQueue:data];
  });
}

- (void)flushToDisk:(BOOL)synchronize {
  dispatch_sync(self.queue, ^{
    [self writeBufferToFile:synchronize];
  });
}

- (void)closeAndSync {
  dispatch_sync(self.queue, ^{
    [self writeBufferToFile:YES];
    if (self.handle != nil) {
      [self.handle closeFile];
      self.handle = nil;
    }
  });
}

@end

@protocol PAGPerfCaseContext <NSObject>

- (BOOL)setupWithFile:(PAGFile*)file size:(CGSize)size hostView:(UIView*)hostView error:(NSString**)error;
- (BOOL)ensureReadyWithLog:(void (^)(NSString* event, NSDictionary* fields))logBlock;
- (FramePerfMetrics)sampleFrameAtProgress:(double)progress;
- (void)teardown;
- (NSString*)renderTarget;
- (NSString*)layerClass;
- (NSString*)gpuName;

@end

@interface PAGPerfOffscreenContext : NSObject <PAGPerfCaseContext>

@property(nonatomic, strong) PAGPlayer* player;
@property(nonatomic, strong) PAGSurface* surface;

@end

@implementation PAGPerfOffscreenContext

- (BOOL)setupWithFile:(PAGFile*)file size:(CGSize)size hostView:(UIView*)hostView error:(NSString**)error {
  (void)hostView;
  self.player = [[PAGPlayer alloc] init];
  self.surface = [PAGSurface MakeOffscreen:size];
  if (self.surface == nil) {
    if (error != nil) {
      *error = @"MakeOffscreen returned nil";
    }
    return NO;
  }
  [self.player setSurface:self.surface];
  [self.player setComposition:file];
  [self.player setCacheEnabled:YES];
  [self.player setUseDiskCache:NO];
  [self.player setMaxFrameRate:0];
  return YES;
}

- (BOOL)ensureReadyWithLog:(void (^)(NSString*, NSDictionary*))logBlock {
  (void)logBlock;
  if (self.surface == nil || self.player == nil) {
    return NO;
  }
  (void)SamplePlayerFrame(self.player, 0.0);
  return YES;
}

- (FramePerfMetrics)sampleFrameAtProgress:(double)progress {
  return SamplePlayerFrame(self.player, progress);
}

- (void)teardown {
  if (self.surface != nil) {
    [self.surface freeCache];
  }
  self.surface = nil;
  self.player = nil;
}

- (NSString*)renderTarget {
  return @"offscreen";
}

- (NSString*)layerClass {
  return @"";
}

- (NSString*)gpuName {
  return DefaultGPUName();
}

@end

@interface PAGPerfLayerContext : NSObject <PAGPerfCaseContext>

@property(nonatomic, weak) UIView* hostView;
@property(nonatomic, strong) PAGView* pagView;

@end

@implementation PAGPerfLayerContext

- (BOOL)setupWithFile:(PAGFile*)file size:(CGSize)size hostView:(UIView*)hostView error:(NSString**)error {
  if (hostView == nil) {
    if (error != nil) {
      *error = @"host view is required for layer target";
    }
    return NO;
  }
  self.hostView = hostView;
  self.pagView = [[PAGView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
  self.pagView.contentScaleFactor = 1.0;
  self.pagView.layer.contentsScale = 1.0;
  self.pagView.userInteractionEnabled = NO;
  self.pagView.hidden = NO;
  self.pagView.alpha = 1.0;
  [self.pagView setSync:YES];
  [self.pagView setCacheEnabled:YES];
  [self.pagView setUseDiskCache:NO];
  [self.pagView setMaxFrameRate:0];
  [self.pagView setComposition:file];
  [self.hostView addSubview:self.pagView];
  [self.hostView bringSubviewToFront:self.pagView];
  [self.hostView setNeedsLayout];
  [self.hostView layoutIfNeeded];
  [self.pagView setNeedsLayout];
  [self.pagView layoutIfNeeded];
  return YES;
}

- (BOOL)ensureReadyWithLog:(void (^)(NSString*, NSDictionary*))logBlock {
  if (self.hostView.window == nil || self.pagView.window == nil) {
    return NO;
  }
  if (![self.pagView ensureRenderSurface]) {
    return NO;
  }
  (void)[self.pagView flushAtProgress:0.0];
  if (logBlock != nil) {
    logBlock(@"surface_ready", @{
      @"width" : @(self.pagView.bounds.size.width),
      @"height" : @(self.pagView.bounds.size.height),
      @"layer_class" : NSStringFromClass(self.pagView.layer.class),
      @"gpu_name" : [self gpuName],
    });
  }
  return YES;
}

- (FramePerfMetrics)sampleFrameAtProgress:(double)progress {
  return SampleViewFrame(self.pagView, progress);
}

- (void)teardown {
  [self.pagView freeCache];
  [self.pagView removeFromSuperview];
  self.pagView = nil;
  self.hostView = nil;
}

- (NSString*)renderTarget {
  return @"layer";
}

- (NSString*)layerClass {
  return self.pagView != nil ? NSStringFromClass(self.pagView.layer.class) : @"";
}

- (NSString*)gpuName {
  if ([self.pagView.layer isKindOfClass:[CAMetalLayer class]]) {
    CAMetalLayer* metalLayer = (CAMetalLayer*)self.pagView.layer;
    return metalLayer.device.name.length > 0 ? metalLayer.device.name : DefaultGPUName();
  }
  return DefaultGPUName();
}

@end

@interface PAGPerfSession : NSObject

- (instancetype)initWithHostView:(UIView*)hostView;
- (void)startBenchmark;

@end

@interface PAGPerfSession ()

@property(nonatomic, weak) UIView* hostView;
@property(nonatomic, strong) NSArray<NSString*>* cases;
@property(nonatomic, strong) NSString* backend;
@property(nonatomic, strong) NSString* buildID;
@property(nonatomic, strong) NSString* renderTarget;
@property(nonatomic, strong) NSString* gpuName;
@property(nonatomic, strong) NSString* outputPath;
@property(nonatomic, strong) PAGPerfLogWriter* logWriter;
@property(nonatomic, strong) dispatch_queue_t benchmarkQueue;
@property(nonatomic, strong) id<PAGPerfCaseContext> context;
@property(nonatomic, strong) PAGFile* file;
@property(nonatomic, strong) NSString* caseName;
@property(nonatomic, strong) NSString* frameLogPrefix;
@property(nonatomic, assign) CGSize size;
@property(nonatomic, assign) NSInteger runs;
@property(nonatomic, assign) NSInteger warmups;
@property(nonatomic, assign) NSInteger maxFrames;
@property(nonatomic, assign) NSInteger frameBatch;
@property(nonatomic, assign) NSInteger stepDelayMs;
@property(nonatomic, assign) NSInteger logFlushFrames;
@property(nonatomic, assign) NSInteger framesSinceLogFlush;
@property(nonatomic, assign) BOOL usesLayerTarget;
@property(nonatomic, assign) NSInteger caseIndex;
@property(nonatomic, assign) NSInteger run;
@property(nonatomic, assign) NSInteger frame;
@property(nonatomic, assign) NSInteger frameCount;
@property(nonatomic, assign) NSInteger totalRuns;
@property(nonatomic, assign) uint64_t loadUs;
@property(nonatomic, assign) uint64_t setupUs;
@property(nonatomic, assign) uint64_t surfaceReadyUs;
@property(nonatomic, assign) BOOL runStarted;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, assign) BOOL awaitingRenderReady;
@property(nonatomic, assign) NSInteger surfaceWaitAttempts;

@end

@implementation PAGPerfSession

- (instancetype)initWithHostView:(UIView*)hostView {
  self = [super init];
  if (self) {
    _hostView = hostView;
    _cases = CaseList();
    _backend = PerfBackend();
    _buildID = PerfBuildID();
    _renderTarget = RenderTargetName();
    _usesLayerTarget = UsesLayerTarget();
    _gpuName = DefaultGPUName();
    _runs = MAX(1, IntegerConfig(kPerfRunsEnv, 5));
    _warmups = MAX(0, IntegerConfig(kPerfWarmupsEnv, 3));
    _maxFrames = IntegerConfig(kPerfMaxFramesEnv, 180);
    _frameBatch = MAX(1, IntegerConfig(kPerfFrameBatchEnv, _usesLayerTarget ? kDefaultLayerFrameBatch
                                                                           : kDefaultOffscreenFrameBatch));
    _stepDelayMs = MAX(0, IntegerConfig(kPerfStepDelayEnv, 0));
    _logFlushFrames = MAX(1, IntegerConfig(kPerfLogFlushEnv, kDefaultLogFlushFrames));
    _outputPath = OutputPath();
    _benchmarkQueue = dispatch_queue_create("com.tencent.pag.perf.benchmark", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)logLine:(NSString*)line {
  [self.logWriter appendLine:line];
}

- (void)logLineAndFlush:(NSString*)line synchronize:(BOOL)synchronize {
  [self.logWriter appendLine:line];
  [self.logWriter flushToDisk:synchronize];
}

- (dispatch_queue_t)workQueue {
  return self.usesLayerTarget ? dispatch_get_main_queue() : self.benchmarkQueue;
}

- (void)updateFrameLogPrefix {
  self.frameLogPrefix =
      [NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"frame\",\"backend\":%@,\"build_id\":%@,"
                                 "\"case\":%@,\"render_target\":%@,\"gpu_name\":%@,\"run\":%ld,"
                                 "\"frame_count\":%ld,",
       static_cast<long>(kPerfSchemaVersion), JSONString(self.backend), JSONString(self.buildID),
       JSONString(self.caseName), JSONString(self.context.renderTarget), JSONString(self.gpuName),
       static_cast<long>(self.run), static_cast<long>(self.frameCount)];
}

- (id<PAGPerfCaseContext>)makeContext {
  if (self.usesLayerTarget) {
    return [[PAGPerfLayerContext alloc] init];
  }
  return [[PAGPerfOffscreenContext alloc] init];
}

- (void)startBenchmark {
  if (self.usesLayerTarget) {
    if (![NSThread isMainThread]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self startBenchmark];
      });
      return;
    }
    [self start];
    return;
  }
  dispatch_async(self.benchmarkQueue, ^{
    [self start];
  });
}

- (void)start {
  NSLog(@"[PAGPerf] benchmark started: %@ (target=%@)", self.outputPath, self.renderTarget);
  self.logWriter = [[PAGPerfLogWriter alloc] initWithPath:self.outputPath];
  if (self.logWriter == nil) {
    NSLog(@"[PAGPerf] failed to open output file: %@", self.outputPath);
    return;
  }

  if (self.usesLayerTarget && self.hostView == nil) {
    [self logLineAndFlush:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"host_view_missing\","
                                                   "\"backend\":%@,\"build_id\":%@,\"render_target\":%@}",
                                                     static_cast<long>(kPerfSchemaVersion),
                                                     JSONString(self.backend), JSONString(self.buildID),
                                                     JSONString(self.renderTarget)]
              synchronize:YES];
    [self finish];
    return;
  }

  NSProcessInfo* processInfo = [NSProcessInfo processInfo];
  NSString* header =
      [NSString stringWithFormat:
                    @"{\"schema\":%ld,\"event\":\"start\",\"backend\":%@,\"device\":%@,\"system\":%@,"
                     "\"system_version\":%@,\"build_id\":%@,\"render_target\":%@,\"gpu_name\":%@,"
                     "\"thermal_state\":%@,\"runs\":%ld,\"warmups\":%ld,\"max_frames\":%ld,"
                     "\"frame_batch\":%ld,\"step_delay_ms\":%ld,\"log_flush_frames\":%ld}",
                    static_cast<long>(kPerfSchemaVersion), JSONString(self.backend),
                    JSONString(DeviceModel()), JSONString(processInfo.operatingSystemVersionString),
                    JSONString([[UIDevice currentDevice] systemVersion]), JSONString(self.buildID),
                    JSONString(self.renderTarget), JSONString(self.gpuName),
                    JSONString(ThermalStateName(processInfo.thermalState)), static_cast<long>(self.runs),
                    static_cast<long>(self.warmups), static_cast<long>(self.maxFrames),
                    static_cast<long>(self.frameBatch), static_cast<long>(self.stepDelayMs),
                    static_cast<long>(self.logFlushFrames)];
  [self logLineAndFlush:header synchronize:YES];
  [self scheduleNextStep];
}

- (void)scheduleNextStep {
  dispatch_queue_t queue = [self workQueue];
  if (self.stepDelayMs <= 0) {
    dispatch_async(queue, ^{
      [self runStepBatch];
    });
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(self.stepDelayMs) * NSEC_PER_MSEC),
                 queue, ^{
                   [self runStepBatch];
                 });
}

- (void)runStepBatch {
  NSInteger steps = self.frameBatch;
  while (!self.finished && steps > 0) {
    [self step];
    steps--;
  }
  if (!self.finished) {
    [self scheduleNextStep];
  }
}

- (void)step {
  @autoreleasepool {
    if (self.context == nil) {
      [self startNextCase];
      return;
    }
    if (self.awaitingRenderReady) {
      if (![self ensureRenderReady]) {
        self.surfaceWaitAttempts++;
        if (self.surfaceWaitAttempts >= kMaxSurfaceWaitAttempts) {
          [self logRenderSurfaceTimeout];
          [self finishCurrentCase];
        }
        return;
      }
      self.awaitingRenderReady = NO;
    }
    if (self.run >= self.runs) {
      [self finishCurrentCase];
      return;
    }
    if (!self.runStarted) {
      [self startCurrentRun];
      return;
    }
    if (self.frame < self.frameCount) {
      [self renderCurrentFrame];
      return;
    }
    [self finishCurrentRun];
  }
}

- (void)startNextCase {
  if (self.caseIndex >= self.cases.count) {
    [self finish];
    return;
  }

  self.caseName = [self.cases objectAtIndex:self.caseIndex];
  [self logLine:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"case_start\","
                                        "\"backend\":%@,\"build_id\":%@,\"case\":%@}",
                                      static_cast<long>(kPerfSchemaVersion),
                                      JSONString(self.backend), JSONString(self.buildID),
                                      JSONString(self.caseName)]];

  NSString* path = BundlePathForCase(self.caseName);
  if (path.length == 0) {
    [self logLineAndFlush:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"missing_case\","
                                                  "\"backend\":%@,\"build_id\":%@,\"case\":%@}",
                                                    static_cast<long>(kPerfSchemaVersion),
                                                    JSONString(self.backend), JSONString(self.buildID),
                                                    JSONString(self.caseName)]
              synchronize:NO];
    self.caseIndex++;
    return;
  }

  uint64_t loadStartUs = NowInMicroseconds();
  self.file = [PAGFile Load:path];
  self.loadUs = NowInMicroseconds() - loadStartUs;
  if (self.file == nil) {
    [self logLineAndFlush:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"load_failed\","
                                                  "\"backend\":%@,\"build_id\":%@,\"case\":%@,\"path\":%@}",
                                                    static_cast<long>(kPerfSchemaVersion),
                                                    JSONString(self.backend), JSONString(self.buildID),
                                                    JSONString(self.caseName), JSONString(path)]
              synchronize:NO];
    self.caseIndex++;
    return;
  }
  [self logLine:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"asset_load\","
                                  "\"backend\":%@,\"build_id\":%@,\"case\":%@,\"path\":%@,"
                                  "\"load_us\":%llu,\"width\":%ld,\"height\":%ld,"
                                  "\"duration_us\":%lld,\"frame_rate\":%.3f}",
                                    static_cast<long>(kPerfSchemaVersion),
                                    JSONString(self.backend), JSONString(self.buildID),
                                    JSONString(self.caseName), JSONString(path), self.loadUs,
                                    static_cast<long>([self.file width]),
                                    static_cast<long>([self.file height]), [self.file duration],
                                    [self.file frameRate]]];

  self.size = CGSizeMake(MAX(1, [self.file width]), MAX(1, [self.file height]));
  self.context = [self makeContext];
  NSString* setupError = nil;
  uint64_t setupStartUs = NowInMicroseconds();
  BOOL setupOK = [self.context setupWithFile:self.file
                                        size:self.size
                                    hostView:self.hostView
                                       error:&setupError];
  self.setupUs = NowInMicroseconds() - setupStartUs;
  if (!setupOK) {
    [self logLineAndFlush:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"setup_failed\","
                                                  "\"backend\":%@,\"build_id\":%@,\"case\":%@,"
                                                  "\"render_target\":%@,\"error\":%@}",
                                                    static_cast<long>(kPerfSchemaVersion),
                                                    JSONString(self.backend), JSONString(self.buildID),
                                                    JSONString(self.caseName),
                                                    JSONString(self.context.renderTarget),
                                                    JSONString(setupError != nil ? setupError : @"unknown")]
              synchronize:NO];
    [self.context teardown];
    self.context = nil;
    self.file = nil;
    self.caseIndex++;
    return;
  }
  self.gpuName = [self.context gpuName];

  self.frameCount = FrameCountForFile(self.file, self.maxFrames);
  self.totalRuns = self.warmups + self.runs;
  self.run = -self.warmups;
  self.frame = 0;
  self.runStarted = NO;
  self.awaitingRenderReady = YES;
  self.surfaceWaitAttempts = 0;
  self.framesSinceLogFlush = 0;
  [self logLineAndFlush:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"context_ready\","
                                          "\"backend\":%@,\"build_id\":%@,\"case\":%@,"
                                          "\"width\":%.0f,\"height\":%.0f,\"frame_rate\":%.3f,"
                                          "\"duration_us\":%lld,\"frames\":%ld,\"total_runs\":%ld,"
                                          "\"load_us\":%llu,\"setup_us\":%llu,"
                                          "\"render_target\":%@,\"layer_class\":%@,\"gpu_name\":%@}",
                                            static_cast<long>(kPerfSchemaVersion),
                                            JSONString(self.backend), JSONString(self.buildID),
                                            JSONString(self.caseName), self.size.width, self.size.height,
                                            [self.file frameRate], [self.file duration],
                                            static_cast<long>(self.frameCount),
                                            static_cast<long>(self.totalRuns),
                                            self.loadUs, self.setupUs,
                                            JSONString(self.context.renderTarget),
                                            JSONString(self.context.layerClass),
                                            JSONString(self.gpuName)]
              synchronize:NO];
}

- (BOOL)ensureRenderReady {
  __block BOOL logged = NO;
  uint64_t readyStartUs = NowInMicroseconds();
  BOOL ready = [self.context ensureReadyWithLog:^(NSString* event, NSDictionary* fields) {
    if (logged) {
      return;
    }
    logged = YES;
    self.surfaceReadyUs = NowInMicroseconds() - readyStartUs;
    [self logLine:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":%@,"
                                  "\"backend\":%@,\"build_id\":%@,\"case\":%@,"
                                  "\"width\":%.0f,\"height\":%.0f,\"layer_class\":%@,"
                                  "\"gpu_name\":%@,\"surface_ready_us\":%llu}",
                              static_cast<long>(kPerfSchemaVersion), JSONString(event),
                              JSONString(self.backend), JSONString(self.buildID),
                              JSONString(self.caseName),
                              [fields[@"width"] doubleValue], [fields[@"height"] doubleValue],
                              JSONString(fields[@"layer_class"]),
                              JSONString(fields[@"gpu_name"]), self.surfaceReadyUs]];
  }];
  if (ready && !logged && ![self.context.renderTarget isEqualToString:@"layer"]) {
    self.surfaceReadyUs = NowInMicroseconds() - readyStartUs;
    [self logLine:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"surface_ready\","
                                  "\"backend\":%@,\"build_id\":%@,\"case\":%@,"
                                  "\"width\":%.0f,\"height\":%.0f,\"render_target\":%@,"
                                  "\"gpu_name\":%@,\"surface_ready_us\":%llu}",
                              static_cast<long>(kPerfSchemaVersion),
                              JSONString(self.backend), JSONString(self.buildID),
                              JSONString(self.caseName), self.size.width, self.size.height,
                              JSONString(self.context.renderTarget),
                              JSONString(self.gpuName), self.surfaceReadyUs]];
  }
  return ready;
}

- (void)logRenderSurfaceTimeout {
  [self logLineAndFlush:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"surface_timeout\","
                                        "\"backend\":%@,\"build_id\":%@,\"case\":%@,"
                                        "\"wait_attempts\":%ld,\"render_target\":%@,\"host_has_window\":%@}",
                                          static_cast<long>(kPerfSchemaVersion),
                                          JSONString(self.backend), JSONString(self.buildID),
                                          JSONString(self.caseName),
                                          static_cast<long>(self.surfaceWaitAttempts),
                                          JSONString(self.context.renderTarget),
                                          self.hostView.window != nil ? @"true" : @"false"]
              synchronize:NO];
  NSLog(@"[PAGPerf] render surface not ready for case %@ after %ld attempts (target=%@)",
        self.caseName, static_cast<long>(self.surfaceWaitAttempts), self.context.renderTarget);
}

- (void)startCurrentRun {
  BOOL warmup = self.run < 0;
  [self logLine:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"run_start\","
                                "\"backend\":%@,\"build_id\":%@,\"case\":%@,"
                                "\"run\":%ld,\"warmup\":%@,\"frames\":%ld}",
                              static_cast<long>(kPerfSchemaVersion),
                              JSONString(self.backend), JSONString(self.buildID),
                              JSONString(self.caseName), static_cast<long>(self.run),
                              warmup ? @"true" : @"false",
                              static_cast<long>(self.frameCount)]];
  if (!warmup) {
    [self updateFrameLogPrefix];
  }
  self.runStarted = YES;
  self.frame = 0;
  self.framesSinceLogFlush = 0;
}

- (void)renderCurrentFrame {
  BOOL warmup = self.run < 0;
  double progress = self.frameCount <= 1 ? 0.0 : static_cast<double>(self.frame) / (self.frameCount - 1);
  FramePerfMetrics metrics = [self.context sampleFrameAtProgress:progress];
  if (!warmup) {
    NSString* line =
        [NSString stringWithFormat:@"%@\"frame\":%ld,\"progress\":%.8f,\"changed\":%@,"
                                   "\"flush_us\":%llu,\"prepare_us\":%lld,\"draw_us\":%lld,"
                                   "\"image_decode_us\":%lld,\"graphics_memory_bytes\":%lld}",
         self.frameLogPrefix, static_cast<long>(self.frame), progress,
         metrics.changed ? @"true" : @"false", metrics.flushUs, metrics.prepareUs, metrics.drawUs,
         metrics.imageDecodeUs, metrics.graphicsMemoryBytes];
    [self logLine:line];
    self.framesSinceLogFlush++;
    if (self.framesSinceLogFlush >= self.logFlushFrames || self.frame + 1 == self.frameCount) {
      [self.logWriter flushToDisk:NO];
      self.framesSinceLogFlush = 0;
    }
  }
  self.frame++;
}

- (void)finishCurrentRun {
  BOOL warmup = self.run < 0;
  [self logLine:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"run_done\","
                                "\"backend\":%@,\"build_id\":%@,\"case\":%@,"
                                "\"run\":%ld,\"warmup\":%@,\"frames\":%ld}",
                              static_cast<long>(kPerfSchemaVersion),
                              JSONString(self.backend), JSONString(self.buildID),
                              JSONString(self.caseName), static_cast<long>(self.run),
                              warmup ? @"true" : @"false",
                              static_cast<long>(self.frameCount)]];
  [self.logWriter flushToDisk:NO];
  self.run++;
  self.frame = 0;
  self.runStarted = NO;
}

- (void)finishCurrentCase {
  if (self.context == nil) {
    self.caseIndex++;
    return;
  }
  [self logLineAndFlush:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"case_done\","
                                      "\"backend\":%@,\"build_id\":%@,\"case\":%@,\"runs\":%ld,"
                                      "\"warmups\":%ld,\"frames\":%ld,\"total_runs\":%ld,"
                                      "\"render_target\":%@}",
                                        static_cast<long>(kPerfSchemaVersion),
                                        JSONString(self.backend), JSONString(self.buildID),
                                        JSONString(self.caseName), static_cast<long>(self.runs),
                                        static_cast<long>(self.warmups), static_cast<long>(self.frameCount),
                                        static_cast<long>(self.totalRuns),
                                        JSONString(self.context.renderTarget)]
              synchronize:NO];
  self.awaitingRenderReady = NO;
  self.surfaceWaitAttempts = 0;
  [self.context teardown];
  self.context = nil;
  self.file = nil;
  self.caseName = nil;
  self.caseIndex++;
}

- (void)finish {
  if (self.finished) {
    return;
  }
  self.finished = YES;
  [self logLine:[NSString stringWithFormat:@"{\"schema\":%ld,\"event\":\"done\",\"backend\":%@,"
                                "\"build_id\":%@,\"render_target\":%@,\"output\":%@}",
                              static_cast<long>(kPerfSchemaVersion),
                              JSONString(self.backend), JSONString(self.buildID),
                              JSONString(self.renderTarget), JSONString(self.outputPath)]];
  [self.logWriter closeAndSync];
  self.logWriter = nil;
  NSLog(@"[PAGPerf] benchmark finished: %@", self.outputPath);
}

@end

@implementation PAGPerfRunner

+ (BOOL)shouldRunFromEnvironment {
  NSString* configuredValue = ConfigValue(kPerfRunEnv, nil);
  if (configuredValue.length > 0) {
    return IsTruthy(configuredValue);
  }
  return NO;
}

+ (void)runFromEnvironment {
  [self runFromEnvironmentInView:nil];
}

+ (void)runFromEnvironmentInView:(UIView*)hostView {
  PAGPerfSession* session = [[PAGPerfSession alloc] initWithHostView:hostView];
  [session startBenchmark];
}

@end
