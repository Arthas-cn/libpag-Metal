/////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Tencent is pleased to support the open source community by making libpag available.
//
//  Copyright (C) 2023 Tencent. All rights reserved.
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

#import "PAGImageView.h"
#include <VideoToolbox/VideoToolbox.h>
#include <algorithm>
#include <mach/mach_time.h>
#include <mutex>

#include "base/utils/TimeUtil.h"
#include "pag/pag.h"
#include "rendering/layers/ContentVersion.h"

#import "PAGFile.h"
#import "platform/cocoa/PAGDiskCache.h"
#import "platform/cocoa/PAG.h"
#import "platform/cocoa/private/PAGAnimator.h"
#import "platform/cocoa/private/PAGLayer+Internal.h"
#import "platform/cocoa/private/PAGLayerImpl+Internal.h"
#import "platform/cocoa/private/PixelBufferUtil.h"

namespace pag {
static NSOperationQueue* imageViewFlushQueue;
void DestoryImageViewFlushQueue() {
  NSOperationQueue* queue = imageViewFlushQueue;
  [queue cancelAllOperations];
  [queue waitUntilAllOperationsAreFinished];
  [queue release];
  queue = nil;
}
}  // namespace pag

static const float DEFAULT_MAX_FRAMERATE = 30.0;

static uint64_t PAGPerfNowInMicroseconds() {
  static mach_timebase_info_data_t timebase = {0, 0};
  if (timebase.denom == 0) {
    mach_timebase_info(&timebase);
  }
  uint64_t now = mach_absolute_time();
  return now * timebase.numer / timebase.denom / 1000;
}

static NSInteger PAGPerfViewIndex(UIView* view) {
  NSString* identifier = view.accessibilityIdentifier;
  NSString* prefix = @"pag_image_view_";
  if (![identifier hasPrefix:prefix]) {
    return -1;
  }
  return [[identifier substringFromIndex:prefix.length] integerValue];
}

static NSString* PAGPerfCaseName(NSString* path) {
  return path.length > 0 ? [path lastPathComponent] : @"";
}

#ifndef dispatch_main_async_safe
#define dispatch_main_async_safe(block)                         \
  if (dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL) == \
      dispatch_queue_get_label(dispatch_get_main_queue())) {    \
    block();                                                    \
  } else {                                                      \
    dispatch_async(dispatch_get_main_queue(), block);           \
  }
#endif

@interface PAGImageView ()
@property(atomic, assign) BOOL isVisible;
@property(atomic, assign) NSInteger currentFrameIndex;
@property(atomic, retain) UIImage* currentUIImage;
@property(nonatomic, assign) BOOL memoryCacheEnabled;
@property(nonatomic, assign) BOOL memeoryCacheFinished;
@property(nonatomic, assign) NSInteger fileWidth;
@property(nonatomic, assign) NSInteger fileHeight;
@property(nonatomic, assign) float maxFrameRate;
@property(nonatomic, assign) CGSize viewSize;

@end

@interface PAGImageView () <PAGAnimatorUpdater, PAGAnimatorListener>
@end

@implementation PAGImageView {
  NSString* filePath;
  PAGAnimator* animator;
  std::shared_ptr<pag::PAGComposition> pagComposition;
  std::shared_ptr<pag::PAGDecoder> pagDecoder;
  int64_t duration;
  float renderScaleFactor;
  NSInteger width;
  NSInteger height;
  NSUInteger numFrames;
  uint32_t pagContentVersion;

  NSMutableDictionary<NSNumber*, UIImage*>* imagesMap;
  std::mutex imageViewLock;
  CVPixelBufferPoolRef diskBufferPool;
  NSHashTable* listeners;
  std::mutex listenerLock;
  uint64_t tracePlaybackStartUs;
  uint64_t traceFrameTotalUs;
  uint64_t traceFrameMaxUs;
  uint64_t traceLastReadFrameUs;
  uint64_t traceLastSequenceReadUs;
  uint64_t traceLastRenderFrameUs;
  uint64_t traceLastSequenceWriteUs;
  uint64_t traceLastDecoderReadTotalUs;
  uint64_t traceLastUIImageUs;
  NSUInteger traceFrameSamples;
  BOOL traceLastCacheHit;
  BOOL traceLastSequenceCacheHit;
  BOOL traceLastRenderedFrame;
  BOOL traceCompletedLoop;
}

@synthesize memoryCacheEnabled = _memoryCacheEnabled;

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    [self initPAG];
  }
  return self;
}

- (void)initPAG {
  pagDecoder = nullptr;
  pagComposition = nullptr;
  self.currentFrameIndex = -1;
  renderScaleFactor = 1.0;
  duration = 0;
  pagContentVersion = 0;
  self.memoryCacheEnabled = NO;
  self.memeoryCacheFinished = NO;
  self.isVisible = NO;
  filePath = nil;
  width = 0;
  height = 0;
  numFrames = 0;
  self.backgroundColor = [UIColor clearColor];
  animator = [[PAGAnimator alloc] initWithUpdater:(id<PAGAnimatorUpdater>)self];
  listeners = [[NSHashTable weakObjectsHashTable] retain];
  [animator addListener:self];
  tracePlaybackStartUs = 0;
  traceFrameTotalUs = 0;
  traceFrameMaxUs = 0;
  traceLastReadFrameUs = 0;
  traceLastSequenceReadUs = 0;
  traceLastRenderFrameUs = 0;
  traceLastSequenceWriteUs = 0;
  traceLastDecoderReadTotalUs = 0;
  traceLastUIImageUs = 0;
  traceFrameSamples = 0;
  traceLastCacheHit = NO;
  traceLastSequenceCacheHit = NO;
  traceLastRenderedFrame = NO;
  traceCompletedLoop = NO;

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationDidBecomeActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
}

- (void)dealloc {
  [animator cancel];
  [animator release];
  [self reset];
  pagComposition = nullptr;
  if (_currentUIImage) {
    [_currentUIImage release];
  }
  if (filePath != nil) {
    [filePath release];
  }
  [listeners release];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super dealloc];
}

#pragma mark - private
+ (NSOperationQueue*)ImageViewFlushQueue {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    pag::imageViewFlushQueue = [[[NSOperationQueue alloc] init] retain];
    pag::imageViewFlushQueue.maxConcurrentOperationCount = 1;
    pag::imageViewFlushQueue.name = @"PAGImageView.art.pag";
  });
  return pag::imageViewFlushQueue;
}

/// 函数用于在执行 exit() 函数时把渲染任务全部完成，防止 PAG 的全局函数被析构，导致 PAG 野指针
/// crash。 注意这里注册需要等待 PAG 执行一次后再进行注册。因此需要等到 bufferPerpared 并再执行一次
/// flush 后, 否则 PAG 的 static 对象仍然会先析构
+ (void)RegisterFlushQueueDestoryMethod {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    atexit(pag::DestoryImageViewFlushQueue);
  });
}

- (void)setCompositionInternal:(std::shared_ptr<pag::PAGComposition>)newComposition
                  maxFrameRate:(float)maxFrameRate {
  if (pagComposition == newComposition) {
    return;
  }
  if (!filePath) {
    pagComposition = newComposition;
  }
  if (newComposition) {
    self.fileWidth = newComposition->width();
    self.fileHeight = newComposition->height();
    pagContentVersion = pag::ContentVersion::Get(newComposition);
    duration = newComposition->duration();
  } else {
    self.fileWidth = 0;
    self.fileHeight = 0;
    pagContentVersion = 0;
    duration = 0;
  }
  self.maxFrameRate = maxFrameRate;
  tracePlaybackStartUs = 0;
  traceFrameTotalUs = 0;
  traceFrameMaxUs = 0;
  traceFrameSamples = 0;
  traceCompletedLoop = NO;

  [self reset];
  [self updatePAGDecoder];
  if (self.isVisible) {
    [animator setDuration:duration];
  }
}

- (CVPixelBufferRef)getDiskCacheCVPixelBuffer {
  if (diskBufferPool == nil) {
    NSDictionary* options = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferWidthKey : @(width),
      (id)kCVPixelBufferHeightKey : @(height),
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, (CFDictionaryRef)options,
                                              &diskBufferPool);
    if (status != kCVReturnSuccess || diskBufferPool == nil) {
      return nil;
    }
  }
  CVPixelBufferRef pixelBuffer;
  CVReturn status =
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, diskBufferPool, &pixelBuffer);
  CVPixelBufferPoolFlush(diskBufferPool, kCVPixelBufferPoolFlushExcessBuffers);
  if (status != kCVReturnSuccess) {
    return nil;
  }
  CFAutorelease(pixelBuffer);
  return pixelBuffer;
}

- (CVPixelBufferRef)getMemoryCacheCVPixelBuffer {
  CVPixelBufferRef pixelBuffer =
      pag::PixelBufferUtil::Make(static_cast<int>(width), static_cast<int>(height));
  if (pixelBuffer == nil) {
    NSLog(@"PAGImageView: CVPixelBufferRef create failed!");
    return nil;
  }
  return pixelBuffer;
}

- (void)updatePAGDecoder {
  if (pagDecoder == nullptr) {
    uint64_t decoderStartUs = PAGPerfNowInMicroseconds();
    float scaleFactor;
    if (self.viewSize.width >= self.viewSize.height) {
      scaleFactor = static_cast<float>(
          renderScaleFactor * (self.viewSize.width * [UIScreen mainScreen].scale / self.fileWidth));
    } else {
      scaleFactor =
          static_cast<float>(renderScaleFactor * (self.viewSize.height *
                                                  [UIScreen mainScreen].scale / self.fileHeight));
    }
    if (pagComposition) {
      pagDecoder = pag::PAGDecoder::MakeFrom(pagComposition, self.maxFrameRate, scaleFactor);
    } else if (filePath) {
      auto file = pag::PAGFile::Load([filePath UTF8String]);
      pagDecoder = pag::PAGDecoder::MakeFrom(file, self.maxFrameRate, scaleFactor);
    }
    if (pagDecoder) {
      width = pagDecoder->width();
      height = pagDecoder->height();
      numFrames = pagDecoder->numFrames();
      if ([PAGPerfTrace Enabled]) {
        [PAGPerfTrace LogEvent:@"decoder_ready"
                        fields:@{
                          @"render_target" : @"image_view",
                          @"case" : PAGPerfCaseName(filePath),
                          @"view_index" : @(PAGPerfViewIndex(self)),
                          @"decoder_create_us" : @(PAGPerfNowInMicroseconds() - decoderStartUs),
                          @"decode_width" : @(width),
                          @"decode_height" : @(height),
                          @"num_frames" : @(numFrames),
                          @"max_frame_rate" : @(self.maxFrameRate),
                          @"render_scale" : @(renderScaleFactor),
                        }];
      }
    }
  }
}

- (void)onAnimationFlush:(double)progress {
  [self flush];
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  [self checkVisible];
}

- (void)checkVisible {
  BOOL visible = self.window && !self.isHidden && self.alpha > 0.0;
  if (self.isVisible == visible) {
    return;
  }
  self.isVisible = visible;
  if (self.isVisible) {
    int64_t currentDuration = pagComposition ? pagComposition->duration() : duration;
    [animator setDuration:currentDuration];
  } else {
    [animator setDuration:0];
  }
}

- (BOOL)updateImageViewFrom:(CVPixelBufferRef)pixelBuffer atIndex:(NSInteger)frameIndex {
  [self freeCache];
  if ([[imagesMap allKeys] containsObject:@(frameIndex)]) {
    traceLastCacheHit = YES;
    UIImage* image = imagesMap[@(frameIndex)];
    if (image) {
      self.currentFrameIndex = frameIndex;
      self.currentUIImage = image;
      [self submitToImageView];
    }
    if ([imagesMap count] == numFrames) {
      self.memeoryCacheFinished = YES;
    }
    return YES;
  }
  [self updatePAGDecoder];
  if (pagDecoder == nullptr) {
    return false;
  }
  if (pagDecoder->checkFrameChanged(static_cast<int>(frameIndex))) {
    uint64_t readFrameStartUs = PAGPerfNowInMicroseconds();
    BOOL status = pagDecoder->readFrame(static_cast<int>(frameIndex), pixelBuffer);
    traceLastReadFrameUs = PAGPerfNowInMicroseconds() - readFrameStartUs;
    traceLastSequenceCacheHit = pagDecoder->lastFrameReadFromCache();
    traceLastRenderedFrame = pagDecoder->lastFrameRendered();
    traceLastSequenceReadUs = static_cast<uint64_t>(pagDecoder->lastSequenceReadTime());
    traceLastRenderFrameUs = static_cast<uint64_t>(pagDecoder->lastRenderFrameTime());
    traceLastSequenceWriteUs = static_cast<uint64_t>(pagDecoder->lastSequenceWriteTime());
    traceLastDecoderReadTotalUs = static_cast<uint64_t>(pagDecoder->lastReadFrameTime());
    if (!status) {
      return status;
    }
    UIImage* image = [self imageForCVPixelBuffer:pixelBuffer];
    if (image) {
      self.currentFrameIndex = frameIndex;
      self.currentUIImage = image;
      [self submitToImageView];
    }
  }
  if (self.memoryCacheEnabled && self.currentUIImage) {
    if (imagesMap == nil) {
      imagesMap = [NSMutableDictionary new];
    }
    self->imagesMap[@(frameIndex)] = self.currentUIImage;
  }

  return YES;
}

- (BOOL)checkPAGCompositionChanged {
  uint32_t currentVersion = pag::ContentVersion::Get(pagComposition);
  if (currentVersion != pagContentVersion) {
    pagContentVersion = currentVersion;
    [self reset];
    [self updatePAGDecoder];
    if (self.isVisible && pagComposition) {
      [animator setDuration:pagComposition->duration()];
    }
    return YES;
  }
  return NO;
}

- (void)submitToImageView {
  uint64_t submitEnqueueUs = PAGPerfNowInMicroseconds();
  NSInteger traceFrameIndex = self.currentFrameIndex;
  NSInteger traceViewIndex = PAGPerfViewIndex(self);
  NSString* traceCase = [PAGPerfCaseName(filePath) retain];
  dispatch_main_async_safe((^{
    uint64_t submitStartUs = PAGPerfNowInMicroseconds();
    [self setImage:self.currentUIImage];
    [self setNeedsDisplay];
    if ([PAGPerfTrace Enabled]) {
      [PAGPerfTrace LogEvent:@"submit"
                      fields:@{
                        @"render_target" : @"image_view",
                        @"case" : traceCase != nil ? traceCase : @"",
                        @"view_index" : @(traceViewIndex),
                        @"frame" : @(traceFrameIndex),
                        @"submit_queue_us" : @(submitStartUs - submitEnqueueUs),
                        @"submit_main_us" : @(PAGPerfNowInMicroseconds() - submitStartUs),
                      }];
    }
    [traceCase release];
  }));
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
  if (self.isVisible) {
    [PAGImageView RegisterFlushQueueDestoryMethod];
    [animator update];
  }
}

- (void)freeCache {
  if (self.memoryCacheEnabled && self->pagDecoder && [self->imagesMap count] == numFrames) {
    self->pagDecoder = nullptr;
  }
}

- (void)reset {
  if (imagesMap) {
    [imagesMap removeAllObjects];
    [imagesMap release];
    imagesMap = nil;
    self.memeoryCacheFinished = NO;
  }
  if (diskBufferPool) {
    CVPixelBufferPoolRelease(diskBufferPool);
    diskBufferPool = nil;
  }
  pagDecoder = nullptr;
  width = 0;
  height = 0;
  numFrames = 0;
}

- (UIImage*)imageForCVPixelBuffer:(CVPixelBufferRef)pixelBuffer {
  if (pixelBuffer == nil) {
    return nil;
  }
  uint64_t startUs = PAGPerfNowInMicroseconds();
  CGImageRef imageRef = nil;
  VTCreateCGImageFromCVPixelBuffer(pixelBuffer, nil, &imageRef);
  UIImage* uiImage = [UIImage imageWithCGImage:imageRef];
  CGImageRelease(imageRef);
  traceLastUIImageUs = PAGPerfNowInMicroseconds() - startUs;
  return uiImage;
}

#pragma mark - pubic

+ (NSUInteger)MaxDiskSize {
  return [PAGDiskCache MaxDiskSize];
}

+ (void)SetMaxDiskSize:(NSUInteger)size {
  [PAGDiskCache SetMaxDiskSize:size];
}

- (void)setBounds:(CGRect)bounds {
  CGRect oldBounds = self.bounds;
  [super setBounds:bounds];
  [self handleSizeChanged:oldBounds.size newSize:bounds.size];
}

- (void)setFrame:(CGRect)frame {
  CGRect oldRect = self.frame;
  [super setFrame:frame];
  [self handleSizeChanged:oldRect.size newSize:frame.size];
}

// Resets and rebuilds the decoder for a size change, then triggers a one-off
// animator update so the first frame is rendered at the new size.
//
// Thread safety note: [animator update] can synchronously flow back into
// -[PAGImageView flush], which also acquires imageViewLock. The critical
// section here only mutates internal state, and the animator update is
// deliberately scheduled after the lock is released to prevent the same
// thread from attempting to re-enter a non-recursive mutex and deadlock.
- (void)handleSizeChanged:(CGSize)oldSize newSize:(CGSize)newSize {
  self.viewSize = newSize;
  if (oldSize.width == newSize.width && oldSize.height == newSize.height) {
    return;
  }
  BOOL shouldUpdateAnimator = NO;
  {
    std::lock_guard<std::mutex> autoLock(imageViewLock);
    if (pagComposition || filePath) {
      [self reset];
      [self updatePAGDecoder];
      shouldUpdateAnimator = (oldSize.width == 0 || oldSize.height == 0);
    }
  }
  if (shouldUpdateAnimator) {
    [animator update];
  }
}

- (void)setRenderScale:(float)scale {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  if (renderScaleFactor == scale) {
    return;
  }
  renderScaleFactor = scale;
  if (pagComposition || filePath) {
    [self reset];
    [self updatePAGDecoder];
  }
}

- (float)renderScale {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  return renderScaleFactor;
}

- (void)setContentScaleFactor:(CGFloat)scaleFactor {
  CGFloat oldScaleFactor = self.contentScaleFactor;
  [super setContentScaleFactor:scaleFactor];
  if (oldScaleFactor != scaleFactor) {
    if (pagComposition || filePath) {
      std::lock_guard<std::mutex> autoLock(imageViewLock);
      [self reset];
      [self updatePAGDecoder];
      self.viewSize = CGSizeMake(self.frame.size.width, self.frame.size.height);
    }
  }
}

- (BOOL)cacheAllFramesInMemory {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  return _memoryCacheEnabled;
}

- (void)setCacheAllFramesInMemory:(BOOL)enable {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  _memoryCacheEnabled = enable;
  if (!_memoryCacheEnabled && imagesMap) {
    [imagesMap removeAllObjects];
    [imagesMap release];
    imagesMap = nil;
  }
}

- (void)setAlpha:(CGFloat)alpha {
  [super setAlpha:alpha];
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  [self checkVisible];
}

- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  [self checkVisible];
}

- (void)play {
  tracePlaybackStartUs = PAGPerfNowInMicroseconds();
  traceFrameTotalUs = 0;
  traceFrameMaxUs = 0;
  traceFrameSamples = 0;
  traceCompletedLoop = NO;
  [animator start];
}

- (void)pause {
  [animator cancel];
}

- (NSUInteger)numFrames {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  return numFrames;
}

- (UIImage*)currentImage {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  return [[_currentUIImage retain] autorelease];
}

- (BOOL)isPlaying {
  return [animator isRunning];
}

- (void)addListener:(id<PAGImageViewListener>)listener {
  if (listener == nil) {
    return;
  }
  std::lock_guard<std::mutex> autoLock(listenerLock);
  [listeners addObject:listener];
}

- (void)removeListener:(id<PAGImageViewListener>)listener {
  if (listener == nil) {
    return;
  }
  std::lock_guard<std::mutex> autoLock(listenerLock);
  [listeners removeObject:listener];
}

#pragma mark - PAGAnimatorListener

- (void)onAnimationStart:(id<PAGAnimatorUpdater>)updater {
  [self dispatchListenerEvent:@selector(onAnimationStart:)];
}

- (void)onAnimationEnd:(id<PAGAnimatorUpdater>)updater {
  [self dispatchListenerEvent:@selector(onAnimationEnd:)];
}

- (void)onAnimationCancel:(id<PAGAnimatorUpdater>)updater {
  [self dispatchListenerEvent:@selector(onAnimationCancel:)];
}

- (void)onAnimationRepeat:(id<PAGAnimatorUpdater>)updater {
  [self dispatchListenerEvent:@selector(onAnimationRepeat:)];
}

- (void)onAnimationUpdate:(id<PAGAnimatorUpdater>)updater {
  [self dispatchListenerEvent:@selector(onAnimationUpdate:)];
}

- (void)dispatchListenerEvent:(SEL)selector {
  if ([NSThread isMainThread]) {
    [self performListenerEventOnMainThread:selector];
    return;
  }
  // Retain self before crossing threads to keep the receiver alive until the
  // dispatched block finishes notifying listeners on the main thread.
  [self retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self performListenerEventOnMainThread:selector];
    [self release];
  });
}

- (void)performListenerEventOnMainThread:(SEL)selector {
  NSArray* copiedListeners = nil;
  {
    std::lock_guard<std::mutex> autoLock(listenerLock);
    copiedListeners = [[listeners allObjects] retain];
  }
  for (id<PAGImageViewListener> listener in copiedListeners) {
    if ([listener respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [listener performSelector:selector withObject:self];
#pragma clang diagnostic pop
    }
  }
  [copiedListeners release];
}

- (int)repeatCount {
  return [animator repeatCount];
}

- (void)setRepeatCount:(int)repeatCount {
  [animator setRepeatCount:repeatCount];
}

- (NSString*)getPath {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  return filePath == nil ? nil : [[filePath retain] autorelease];
}

- (BOOL)setPath:(NSString*)newPath {
  return [self setPath:newPath maxFrameRate:DEFAULT_MAX_FRAMERATE];
}

- (BOOL)setPath:(NSString*)path maxFrameRate:(float)maxFrameRate {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  if (filePath != nil) {
    [filePath release];
    filePath = nil;
  }
  filePath = [path retain];
  uint64_t loadStartUs = PAGPerfNowInMicroseconds();
  auto file = pag::PAGFile::Load([path UTF8String]);
  uint64_t loadUs = PAGPerfNowInMicroseconds() - loadStartUs;
  if ([PAGPerfTrace Enabled]) {
    [PAGPerfTrace LogEvent:@"asset_load"
                    fields:@{
                      @"render_target" : @"image_view",
                      @"case" : PAGPerfCaseName(path),
                      @"view_index" : @(PAGPerfViewIndex(self)),
                      @"path" : path != nil ? path : @"",
                      @"load_us" : @(loadUs),
                      @"width" : @(file ? file->width() : 0),
                      @"height" : @(file ? file->height() : 0),
                      @"duration_us" : @(file ? file->duration() : 0),
                      @"frame_rate" : @(file ? file->frameRate() : 0),
                    }];
  }
  [self setCompositionInternal:file maxFrameRate:maxFrameRate];
  return file != nullptr;
}

- (void)setPathAsync:(NSString*)path completionBlock:(void (^)(PAGFile*))callback {
  [self setPathAsync:path
         maxFrameRate:DEFAULT_MAX_FRAMERATE
      completionBlock:^(PAGFile* pagFile) {
        callback(pagFile);
      }];
}

- (void)setPathAsync:(NSString*)path
        maxFrameRate:(float)maxFrameRate
     completionBlock:(void (^)(PAGFile*))callback {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  if (filePath != nil) {
    [filePath release];
    filePath = nil;
  }
  filePath = [path retain];
  [self retain];
  [PAGFile LoadAsync:path
      completionBlock:^(PAGFile* pagFile) {
        std::shared_ptr<pag::PAGFile> cppFile = nullptr;
        if (pagFile != nil) {
          auto layer = [[pagFile impl] pagLayer];
          cppFile = std::static_pointer_cast<pag::PAGFile>(layer);
        }
        imageViewLock.lock();
        [self setCompositionInternal:cppFile maxFrameRate:maxFrameRate];
        imageViewLock.unlock();
        callback(pagFile);
        [self release];
      }];
}

- (PAGComposition*)getComposition {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  if (filePath || pagComposition == nullptr) {
    return nil;
  }
  return (PAGComposition*)[PAGLayerImpl ToPAGLayer:pagComposition];
}

- (void)setComposition:(PAGComposition*)newComposition {
  [self setComposition:newComposition maxFrameRate:DEFAULT_MAX_FRAMERATE];
}

- (void)setComposition:(PAGComposition*)newComposition maxFrameRate:(float)maxFrameRate {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  if (filePath) {
    [filePath release];
    filePath = nil;
  }
  std::shared_ptr<pag::PAGComposition> cppComposition = nullptr;
  if (newComposition != nil) {
    auto layer = [[newComposition impl] pagLayer];
    cppComposition = std::static_pointer_cast<pag::PAGComposition>(layer);
  }
  [self setCompositionInternal:cppComposition maxFrameRate:maxFrameRate];
}

- (void)setCurrentFrame:(NSUInteger)currentFrame {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  [animator setProgress:pag::FrameToProgress(currentFrame, numFrames)];
}

- (NSUInteger)currentFrame {
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  return [self currentFrameInternal];
}

- (NSUInteger)currentFrameInternal {
  return pag::ProgressToFrame([animator progress], numFrames);
}

- (void)logTraceFrameAtIndex:(NSInteger)frameIndex
                    progress:(double)progress
                     changed:(BOOL)changed
                      wallUs:(uint64_t)wallUs {
  if (![PAGPerfTrace Enabled]) {
    return;
  }
  traceFrameTotalUs += wallUs;
  traceFrameMaxUs = std::max(traceFrameMaxUs, wallUs);
  traceFrameSamples++;
  [PAGPerfTrace LogEvent:@"frame"
                  fields:@{
                    @"render_target" : @"image_view",
                    @"case" : PAGPerfCaseName(filePath),
                    @"view_index" : @(PAGPerfViewIndex(self)),
                    @"frame" : @(frameIndex),
                    @"frame_count" : @(numFrames),
                    @"progress" : @(progress),
                    @"changed" : @(changed),
                    @"wall_us" : @(wallUs),
                    @"read_frame_us" : @(traceLastReadFrameUs),
                    @"decoder_read_total_us" : @(traceLastDecoderReadTotalUs),
                    @"sequence_cache_hit" : @(traceLastSequenceCacheHit),
                    @"render_frame" : @(traceLastRenderedFrame),
                    @"sequence_read_us" : @(traceLastSequenceReadUs),
                    @"render_frame_us" : @(traceLastRenderFrameUs),
                    @"sequence_write_us" : @(traceLastSequenceWriteUs),
                    @"uiimage_us" : @(traceLastUIImageUs),
                    @"cache_hit" : @(traceLastCacheHit),
                    @"memory_cache_finished" : @(self.memeoryCacheFinished),
                  }];
  if (!traceCompletedLoop && numFrames > 0 && frameIndex >= static_cast<NSInteger>(numFrames - 1)) {
    traceCompletedLoop = YES;
    uint64_t totalUs = tracePlaybackStartUs > 0 ? PAGPerfNowInMicroseconds() - tracePlaybackStartUs : 0;
    uint64_t averageUs = traceFrameSamples > 0 ? traceFrameTotalUs / traceFrameSamples : 0;
    [PAGPerfTrace LogEvent:@"pag_complete"
                    fields:@{
                      @"render_target" : @"image_view",
                      @"case" : PAGPerfCaseName(filePath),
                      @"view_index" : @(PAGPerfViewIndex(self)),
                      @"frames" : @(traceFrameSamples),
                      @"frame_count" : @(numFrames),
                      @"total_us" : @(totalUs),
                      @"average_wall_us" : @(averageUs),
                      @"max_wall_us" : @(traceFrameMaxUs),
                    }];
  }
}

- (BOOL)flush {
  uint64_t flushStartUs = PAGPerfNowInMicroseconds();
  std::lock_guard<std::mutex> autoLock(imageViewLock);
  NSInteger frameIndex = [self currentFrameInternal];
  double progress = [animator progress];
  traceLastReadFrameUs = 0;
  traceLastSequenceReadUs = 0;
  traceLastRenderFrameUs = 0;
  traceLastSequenceWriteUs = 0;
  traceLastDecoderReadTotalUs = 0;
  traceLastUIImageUs = 0;
  traceLastCacheHit = NO;
  traceLastSequenceCacheHit = NO;
  traceLastRenderedFrame = NO;
  if (self.memeoryCacheFinished) {
    if ([self checkPAGCompositionChanged] == NO) {
      if (self.currentFrameIndex != frameIndex) {
        UIImage* image = imagesMap[@(frameIndex)];
        if (image) {
          traceLastCacheHit = YES;
          self.currentFrameIndex = frameIndex;
          self.currentUIImage = image;
          [self submitToImageView];
          [self logTraceFrameAtIndex:frameIndex
                             progress:progress
                              changed:YES
                               wallUs:PAGPerfNowInMicroseconds() - flushStartUs];
          return YES;
        }
      }
    }
  }
  if (self.currentFrameIndex == frameIndex) {
    [self logTraceFrameAtIndex:frameIndex
                       progress:progress
                        changed:NO
                         wallUs:PAGPerfNowInMicroseconds() - flushStartUs];
    return NO;
  }
  [self checkPAGCompositionChanged];
  CVPixelBufferRef pixelBuffer = self.memoryCacheEnabled ? [self getMemoryCacheCVPixelBuffer]
                                                         : [self getDiskCacheCVPixelBuffer];
  if (pixelBuffer == nil) {
    self.currentUIImage = nil;
    [self submitToImageView];
    [self logTraceFrameAtIndex:frameIndex
                       progress:progress
                        changed:NO
                         wallUs:PAGPerfNowInMicroseconds() - flushStartUs];
    return NO;
  }
  BOOL changed = [self updateImageViewFrom:pixelBuffer atIndex:frameIndex];
  [self logTraceFrameAtIndex:frameIndex
                     progress:progress
                      changed:changed
                       wallUs:PAGPerfNowInMicroseconds() - flushStartUs];
  return changed;
}

@end
