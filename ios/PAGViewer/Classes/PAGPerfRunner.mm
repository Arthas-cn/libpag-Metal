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
#import <QuartzCore/QuartzCore.h>
#import <libpag/PAG.h>
#import <libpag/PAGPlayer.h>
#import <libpag/PAGSurface.h>
#import <libpag/PAGView.h>
#import <mach/mach_time.h>
#include <algorithm>
#include <cmath>

namespace {
NSString* const kPerfRunEnv = @"PAG_PERF_RUN";
NSString* const kPerfCasesEnv = @"PAG_PERF_CASES";
NSString* const kPerfRunsEnv = @"PAG_PERF_RUNS";
NSString* const kPerfWarmupsEnv = @"PAG_PERF_WARMUPS";
NSString* const kPerfMaxFramesEnv = @"PAG_PERF_MAX_FRAMES";
NSString* const kPerfTargetEnv = @"PAG_PERF_TARGET";
NSInteger const kMaxSurfaceWaitAttempts = 3000;

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
    NSString* trimmed =
        [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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

struct FramePerfMetrics {
  BOOL changed;
  uint64_t flushUs;
  int64_t renderUs;
  int64_t presentUs;
  int64_t imageDecodeUs;
  int64_t graphicsMemoryBytes;
};

FramePerfMetrics SamplePlayerFrame(PAGPlayer* player, double progress) {
  [player setProgress:progress];
  uint64_t start = NowInMicroseconds();
  BOOL changed = [player flush];
  uint64_t flushUs = NowInMicroseconds() - start;
  int64_t renderUs = [player renderingTime];
  int64_t presentUs = [player presentingTime];
  int64_t imageDecodeUs = [player imageDecodingTime];
  int64_t graphicsMemoryBytes = [player graphicsMemory];
  if (!changed) {
    renderUs = -1;
    presentUs = -1;
    imageDecodeUs = -1;
    graphicsMemoryBytes = -1;
  }
  return {changed, flushUs, renderUs, presentUs, imageDecodeUs, graphicsMemoryBytes};
}

FramePerfMetrics SampleViewFrame(PAGView* pagView, double progress) {
  uint64_t start = NowInMicroseconds();
  BOOL changed = [pagView flushAtProgress:progress];
  uint64_t flushUs = NowInMicroseconds() - start;
  int64_t renderUs = [pagView renderingTime];
  int64_t presentUs = [pagView presentingTime];
  int64_t imageDecodeUs = [pagView imageDecodingTime];
  int64_t graphicsMemoryBytes = [pagView graphicsMemory];
  if (!changed) {
    renderUs = -1;
    presentUs = -1;
    imageDecodeUs = -1;
    graphicsMemoryBytes = -1;
  }
  return {changed, flushUs, renderUs, presentUs, imageDecodeUs, graphicsMemoryBytes};
}
}  // namespace

@implementation PAGPerfRunner

+ (BOOL)shouldRunFromEnvironment {
  return IsTruthy(ConfigValue(kPerfRunEnv, nil));
}

+ (void)runFromEnvironmentInView:(UIView*)hostView {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self runInView:hostView];
  });
}

+ (void)runInView:(UIView*)hostView {
  [PAGPerfTrace StartSessionWithScenario:@"pag_perf_runner"];
  NSString* target = RenderTargetName();
  NSInteger runs = std::max<NSInteger>(1, IntegerConfig(kPerfRunsEnv, 1));
  NSInteger warmups = std::max<NSInteger>(0, IntegerConfig(kPerfWarmupsEnv, 1));
  NSInteger maxFrames = IntegerConfig(kPerfMaxFramesEnv, 0);
  [PAGPerfTrace LogEvent:@"start"
                  fields:@{
                    @"render_target" : target,
                    @"gl_api" : @"opengles",
                    @"layer_class" : UsesLayerTarget() ? @"CAEAGLLayer" : @"offscreen",
                    @"runs" : @(runs),
                    @"warmups" : @(warmups),
                    @"max_frames" : @(maxFrames),
                  }];

  for (NSString* caseName in CaseList()) {
    NSString* path = BundlePathForCase(caseName);
    uint64_t loadStartUs = NowInMicroseconds();
    PAGFile* file = path.length > 0 ? [PAGFile Load:path] : nil;
    uint64_t loadUs = NowInMicroseconds() - loadStartUs;
    [PAGPerfTrace LogEvent:@"asset_load"
                    fields:@{
                      @"render_target" : target,
                      @"case" : caseName,
                      @"path" : path != nil ? path : @"",
                      @"load_us" : @(loadUs),
                      @"width" : @(file != nil ? [file width] : 0),
                      @"height" : @(file != nil ? [file height] : 0),
                      @"duration_us" : @(file != nil ? [file duration] : 0),
                      @"frame_rate" : @(file != nil ? [file frameRate] : 0),
                    }];
    if (file == nil) {
      [PAGPerfTrace LogEvent:@"case_done"
                      fields:@{@"render_target" : target, @"case" : caseName, @"error" : @"load_failed"}];
      continue;
    }

    CGSize size = CGSizeMake(std::max<CGFloat>(1.0, [file width]),
                             std::max<CGFloat>(1.0, [file height]));
    NSInteger frameCount = FrameCountForFile(file, maxFrames);
    PAGPlayer* player = nil;
    PAGSurface* surface = nil;
    PAGView* pagView = nil;
    uint64_t setupStartUs = NowInMicroseconds();
    if (UsesLayerTarget()) {
      pagView = [[PAGView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
      [pagView setComposition:file];
      [hostView addSubview:pagView];
      for (NSInteger attempt = 0; attempt < kMaxSurfaceWaitAttempts; attempt++) {
        if ([pagView ensureRenderSurface]) {
          break;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
      }
    } else {
      player = [[PAGPlayer alloc] init];
      surface = [PAGSurface MakeOffscreen:size];
      [player setSurface:surface];
      [player setComposition:file];
      [player setCacheEnabled:YES];
      [player setUseDiskCache:NO];
      [player setMaxFrameRate:0];
    }
    uint64_t setupUs = NowInMicroseconds() - setupStartUs;
    BOOL ready = UsesLayerTarget() ? [pagView ensureRenderSurface] : (player != nil && surface != nil);
    [PAGPerfTrace LogEvent:@"surface_ready"
                    fields:@{
                      @"render_target" : target,
                      @"case" : caseName,
                      @"setup_us" : @(setupUs),
                      @"surface_ready" : @(ready),
                      @"layer_class" : UsesLayerTarget() ? @"CAEAGLLayer" : @"offscreen",
                      @"gl_api" : @"opengles",
                    }];
    if (!ready) {
      [PAGPerfTrace LogEvent:@"case_done"
                      fields:@{@"render_target" : target, @"case" : caseName, @"error" : @"surface_failed"}];
      [pagView removeFromSuperview];
      continue;
    }

    for (NSInteger run = -warmups; run < runs; run++) {
      BOOL warmup = run < 0;
      [PAGPerfTrace LogEvent:@"run_start"
                      fields:@{
                        @"render_target" : target,
                        @"case" : caseName,
                        @"run" : @(run),
                        @"warmup" : @(warmup),
                        @"frame_count" : @(frameCount),
                      }];
      uint64_t runStartUs = NowInMicroseconds();
      for (NSInteger frame = 0; frame < frameCount; frame++) {
        double progress = frameCount <= 1 ? 0.0 : static_cast<double>(frame) / (frameCount - 1);
        FramePerfMetrics metrics = UsesLayerTarget() ? SampleViewFrame(pagView, progress)
                                                     : SamplePlayerFrame(player, progress);
        if (!warmup) {
          [PAGPerfTrace LogEvent:@"frame"
                          fields:@{
                            @"render_target" : target,
                            @"case" : caseName,
                            @"run" : @(run),
                            @"frame" : @(frame),
                            @"frame_count" : @(frameCount),
                            @"progress" : @(progress),
                            @"changed" : @(metrics.changed),
                            @"flush_us" : @(metrics.flushUs),
                            @"render_us" : @(metrics.renderUs),
                            @"present_us" : @(metrics.presentUs),
                            @"image_decode_us" : @(metrics.imageDecodeUs),
                            @"graphics_memory_bytes" : @(metrics.graphicsMemoryBytes),
                            @"gl_api" : @"opengles",
                          }];
        }
      }
      [PAGPerfTrace LogEvent:@"run_done"
                      fields:@{
                        @"render_target" : target,
                        @"case" : caseName,
                        @"run" : @(run),
                        @"warmup" : @(warmup),
                        @"total_us" : @(NowInMicroseconds() - runStartUs),
                      }];
      [PAGPerfTrace Flush];
    }
    [PAGPerfTrace LogEvent:@"case_done"
                    fields:@{@"render_target" : target, @"case" : caseName, @"frame_count" : @(frameCount)}];
    [surface freeCache];
    [pagView removeFromSuperview];
  }
  [PAGPerfTrace Close];
}

@end
