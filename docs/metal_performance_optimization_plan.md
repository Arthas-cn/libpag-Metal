# Metal Performance Optimization Plan

## Summary

The current iOS Metal branch is slower than the OpenGL branch in the 20 `PAGImageView` viewer
scenario because that scenario does not use Metal as a direct presentation backend. It uses Metal as
an offscreen frame generator, then synchronously waits for GPU completion, converts the result to a
`UIImage`, and finally displays it through `UIImageView`.

The logs support this diagnosis:

| Metric | Metal Viewer | OpenGL Viewer |
| --- | ---: | ---: |
| True render frame median wall time | 26.48 ms | 16.37 ms |
| True render frame p95 wall time | 92.76 ms | 37.69 ms |
| Overall frame p95 wall time | 72.00 ms | 34.62 ms |
| Max frame wall time | 1230.49 ms | 91.89 ms |

Metal can still outperform OpenGL on iOS, but only if the playback path is changed to avoid CPU
readback, avoid `UIImage` conversion during normal playback, reuse Metal resources aggressively, and
present directly to `CAMetalLayer` or another GPU-native consumer. The `UIImage` conversion is not a
Metal-only cost; it is a shared architectural cost of the current `PAGImageView` model. Metal's
additional disadvantage in this branch comes from forced GPU waits, Metal texture import churn,
fragmented device/context/cache lifetime, and possible runtime pipeline compilation.

## Why Metal Is Slower In The Current PAGImageView Test

`PAGImageView` is not a direct Metal layer path today. Its frame pipeline is:

1. `PAGImageView.flush()` picks the current animation frame.
2. `PAGImageView` obtains a `CVPixelBuffer`.
3. `PAGDecoder::readFrame(index, pixelBuffer)` renders or reads the frame into that buffer.
4. Cache misses call `PAGDecoder::renderFrame()`.
5. `renderFrame()` uses `CompositionReader`.
6. `CompositionReader` renders through `BitmapDrawable`.
7. `BitmapDrawable` uses Metal on iOS.
8. The result is synchronized back to the CPU-visible `CVPixelBuffer`.
9. `VTCreateCGImageFromCVPixelBuffer()` converts the buffer to `CGImage`.
10. `UIImageView.setImage()` presents the generated `UIImage` on the main thread.

Important source locations:

| Area | File | Function |
| --- | --- | --- |
| Per-frame buffer selection | `src/platform/ios/PAGImageView.mm` | `flush`, `getDiskCacheCVPixelBuffer`, `getMemoryCacheCVPixelBuffer` |
| Decoder call | `src/platform/ios/PAGImageView.mm` | `updateImageViewFrom:atIndex:` |
| UIImage conversion | `src/platform/ios/PAGImageView.mm` | `imageForCVPixelBuffer:` |
| Main-thread image submission | `src/platform/ios/PAGImageView.mm` | `submitToImageView` |
| Cache miss and render split | `src/rendering/PAGDecoder.cpp` | `readFrameInternal`, `renderFrame` |
| Offscreen reader | `src/rendering/CompositionReader.cpp` | `readFrame`, `renderFrame` |
| Metal-backed bitmap drawable | `src/rendering/drawables/BitmapDrawable.cpp` | `Make`, `setBitmap`, `present` |
| Metal device creation | `third_party/tgfx/src/gpu/metal/MetalDevice.mm` | `Make` |
| Metal readback/wait | `third_party/tgfx/src/gpu/metal/MetalBuffer.mm` | `map` |
| Metal texture-to-buffer copy | `third_party/tgfx/src/gpu/metal/MetalCommandEncoder.mm` | `copyTextureToBuffer` |

## Current Synchronization And Long-Tail Causes

### 1. Normal Playback Forces GPU Completion

For hardware-backed `CVPixelBuffer` output, `BitmapDrawable::present()` calls
`context->flushAndSubmit(true)`. The `true` means CPU waits for GPU completion before returning.
That removes Metal's normal async advantage.

OpenGL also has synchronous behavior in the equivalent path. The shared `UIImage` conversion keeps
both backends on a CPU-visible output path, while this Metal implementation adds extra backend costs
around command buffers, render target import, texture cache churn, fragmented resource lifetime, and
pipeline compilation.

### 2. PAGImageView Converts Every Rendered Frame To UIImage

After `readFrame()`, `PAGImageView` calls `VTCreateCGImageFromCVPixelBuffer()` and wraps the result
as a `UIImage`. This is required for the current `UIImageView` presentation model, but it prevents a
GPU-native display path.

The logs show `uiimage_us` is not the main median cost, yet it is still part of the architecture
that requires waiting for GPU completion before the frame can be displayed.

### 3. CVPixelBuffer / Surface / Texture Churn

`PAGImageView` obtains a `CVPixelBuffer` for many frames. The disk-cache path takes buffers from a
pool and currently flushes excess buffers each frame; the memory-cache path creates a new
`CVPixelBuffer` through `PixelBufferUtil::Make()`. In both paths, `BitmapBuffer::Wrap(pixelBuffer)`
creates a new wrapper object. `BitmapDrawable::setBitmap()` compares that wrapper pointer, so it can
trigger `freeSurface()` even when the underlying buffer characteristics are stable. The next frame may
then re-import the buffer through `CVMetalTextureCacheCreateTextureFromImage()`.

This can increase p95/p99 even when median render work looks reasonable.

### 4. Metal Device / Context / Cache Lifetime Is Too Fragmented

`BitmapDrawable::Make()` creates a new `MetalDevice` on iOS. `MetalDevice::Make()` creates a Metal
device wrapper and a new `MetalGPU`/command queue stack. In the 20-view scenario this can fragment
program cache, texture cache, resource cache, and command queue lifetime across views or decoders.

This is especially important because TGFX already has program/global cache machinery. If each view or
decoder uses a short-lived Metal context, that cache cannot fully amortize shader, pipeline, texture,
and resource setup costs across the real workload.

### 5. Runtime Metal Shader And Pipeline Compilation

The Metal backend can compile shader modules and render pipeline states synchronously on first use.
New effects, filters, or pipeline descriptors can therefore create long-tail frames.

Relevant files:

- `third_party/tgfx/src/gpu/metal/MetalShaderModule.mm`
- `third_party/tgfx/src/gpu/metal/MetalRenderPipeline.mm`
- `third_party/tgfx/src/gpu/ProgramInfo.cpp`
- `src/rendering/filters/RuntimeFilter.cpp`

### 6. Sequence Cache Writes Compound Cold-Frame Cost

On cache miss, `PAGDecoder::readFrameInternal()` renders the frame and then writes it to
`SequenceFile`. This is not Metal-specific, but when it follows a forced Metal GPU wait it compounds
cold-cache frame cost.

## Can Metal Be Faster Than OpenGL?

Yes, but not by keeping the current `PAGImageView -> CVPixelBuffer -> UIImageView` path as the
primary playback path.

Metal should be faster when the pipeline is:

```text
PAG composition -> PAGPlayer/PAGSurface -> CAMetalLayer drawable -> present
```

or:

```text
PAG composition -> PAGPlayer/PAGSurface -> reusable IOSurface/MTLTexture -> GPU consumer
```

Metal is unlikely to win consistently if each frame must become a CPU-visible `UIImage` before it is
displayed.

## Optimization Roadmap

### Phase 0: Improve Instrumentation Before Changing Behavior

Goal: make the next logs prove which optimization moved which metric.

Files:

- `src/platform/ios/PAGImageView.mm`
- `src/rendering/drawables/BitmapDrawable.cpp`
- `src/rendering/PAGSurface.cpp`
- `third_party/tgfx/src/gpu/metal/MetalCommandQueue.mm`
- `third_party/tgfx/src/gpu/metal/MetalBuffer.mm`
- `ios/PAGViewer/Classes/PAGPerfRunner.mm`

Add or refine fields:

- `gpu_wait_us`
- `surface_recreate_us`
- `cvmetal_texture_import_us`
- `command_commit_us`
- `pipeline_compile_us`
- `uiimage_us`
- `next_drawable_us`
- `sequence_write_us`

Expected outcome:

- Confirm whether p95 is dominated by GPU wait, texture import, pipeline compile, sequence write, or
  UIKit conversion.

Validation:

- `PAGViewer` log still emits `start`, `asset_load`, `decoder_ready`, `frame`, `submit`,
  `pag_complete`, `export_snapshot`, and `done`.
- New fields are sparse-safe and do not break OpenGL comparison.

### Phase 1: Reduce PAGImageView Churn Without Changing Public API

Goal: stabilize the existing `UIImageView` implementation while keeping behavior unchanged.

Files:

- `src/platform/ios/PAGImageView.mm`
- `src/rendering/CompositionReader.cpp`
- `src/rendering/drawables/BitmapDrawable.cpp`
- `src/rendering/utils/BitmapBuffer.*`
- `third_party/tgfx/src/gpu/metal/MetalHardwareTexture.mm`

Implementation ideas:

- Stop flushing the `CVPixelBufferPool` on every frame unless memory pressure requires it.
- Use a small ring of reusable `CVPixelBuffer` objects.
- Preserve `BitmapDrawable` surfaces when the underlying hardware buffer, dimensions, format, and
  color type are compatible.
- Avoid destroying Metal-backed surfaces just because the `BitmapBuffer` wrapper object changed.
- Add texture import cache metrics and reuse where safe.

Expected benefit:

- Lower p95/p99 by reducing texture import and resource churn.
- Hypothesis to validate: Metal true-render p95 can move materially below the current 92 ms baseline,
  potentially toward the 50-70 ms range. This phase still keeps GPU waits and `UIImage` conversion,
  so it is not expected to fully match the OpenGL baseline by itself.

Risks:

- Buffer lifetime bugs can show stale frames.
- Reuse must respect size, row bytes, format, alpha type, and content version.

Validation:

- No visual artifacts in 20-view playback.
- `surface_recreate_us` approaches zero in steady state.
- `cvmetal_texture_import_us` drops after warmup.
- `render_frame=true` p95 improves without increasing memory unboundedly.

### Phase 2: Make PAGImageView GPU-Native On Metal

Goal: make normal playback present directly to Metal instead of generating `UIImage` per frame.

Files:

- `src/platform/ios/PAGImageView.h`
- `src/platform/ios/PAGImageView.mm`
- `src/platform/ios/PAGView.mm`
- `src/platform/ios/private/GPUDrawable.mm`
- `src/platform/ios/private/PAGSurfaceImpl.mm`
- `src/rendering/PAGSurface.cpp`

Implementation direction:

- Keep the public `PAGImageView` API stable where possible.
- Prefer an internal `PAGView`-like renderer or `CAMetalLayer` sublayer owned by `PAGImageView`,
  reusing the existing `PAGSurface::FromLayer(CAMetalLayer*)` and `GPUDrawable` path.
- Render via `PAGPlayer` and `PAGSurface::FromLayer(CAMetalLayer*)`.
- Treat `UIImage` generation as a snapshot/readback operation, not as the normal playback path.
- Preserve current listener, repeat, progress, frame, scale mode, and visibility semantics.
- Define compatibility behavior for `image`, current-frame snapshot, `contentMode`, bounds changes,
  alpha/hidden state, transparency, and `UIImageView` inheritance before implementation.

Expected benefit:

- This is the main path that can make Metal outperform OpenGL.
- Primary target: remove normal-playback `UIImage` conversion and per-frame CPU/GPU completion waits,
  then measure against the OpenGL baseline on the same assets and device.
- Stretch target after a Metal-layer baseline exists: match or beat the OpenGL true-render median and
  p95 from the 2026-07-03 logs.

Risks:

- `PAGImageView` currently subclasses `UIImageView`; replacing presentation internals must preserve
  compatibility with existing users.
- Snapshot/current image semantics need a fallback readback path.
- Transparency, content mode, bounds changes, and hidden/window transitions must match existing
  behavior.

Validation:

- Normal playback does not call `VTCreateCGImageFromCVPixelBuffer()`.
- Normal playback does not emit `uiimage_us`.
- `render_target=image_view_metal_layer` or equivalent appears in logs.
- 20-view playback is visually correct and faster than OpenGL on true-render frames.

### Phase 3: Add A Zero-Copy IOSurface / MTLTexture Output Path

Goal: support GPU-native offscreen consumers without forcing `UIImage`.

Files:

- `src/platform/ios/PAGSurface.h`
- `src/platform/ios/PAGSurface.m`
- `src/platform/ios/private/PAGSurfaceImpl.mm`
- `src/rendering/drawables/HardwareBufferDrawable.cpp`
- `third_party/tgfx/src/gpu/metal/MetalHardwareTexture.mm`
- `third_party/tgfx/src/gpu/metal/MetalGPU.mm`

Implementation direction:

- Provide a stable CVPixelBuffer/IOSurface-backed output API for clients that need offscreen frames.
- Reuse `CVMetalTextureCache` and long-lived Metal resources.
- Add explicit completion/fence semantics so consumers know when a GPU-written buffer is safe.

Expected benefit:

- High benefit for video composition, camera effects, and other GPU consumers.
- Avoids CPU readback while keeping an offscreen API.

Risks:

- More complicated lifecycle and synchronization contract.
- Consumers may misuse buffers before GPU completion unless the API is explicit.

Validation:

- Zero `readPixels` in normal offscreen GPU-consumer playback.
- Stable buffer reuse across frames.
- Explicit completion signal or callback works reliably.

### Phase 4: Reuse Metal Device, Context, Command Queue, And Caches

Goal: avoid repeatedly rebuilding Metal backend state.

Files:

- `third_party/tgfx/src/gpu/metal/MetalDevice.mm`
- `src/rendering/PAGSurfaceFactory.cpp`
- `src/rendering/drawables/BitmapDrawable.cpp`
- `src/rendering/drawables/OffscreenDrawable.cpp`
- `src/rendering/drawables/HardwareBufferDrawable.cpp`

Implementation direction:

- Introduce a shared/default Metal device for iOS where thread ownership is safe.
- Keep `MetalGPU`, command queue, texture cache, and resource cache alive across multiple views.
- Make destruction explicit and safe around memory warnings.

Expected benefit:

- Lower setup time and first-frame cost.
- Better pipeline/texture cache reuse across 20 simultaneous views.

Risks:

- TGFX contexts have owner-thread assumptions.
- A global cache can retain too much memory if purge policy is weak.

Validation:

- `setup_us` and frame-0 p95 decrease.
- Metal backend object count remains stable during 20-view playback.
- Memory pressure handling releases purgeable resources.

### Phase 5: Prewarm And Cache Metal Pipelines

Goal: remove shader and render pipeline compilation from interactive frames.

Files:

- `third_party/tgfx/src/gpu/metal/MetalShaderModule.mm`
- `third_party/tgfx/src/gpu/metal/MetalRenderPipeline.mm`
- `src/rendering/caches/RenderCache.*`
- `src/rendering/filters/RuntimeFilter.cpp`

Implementation direction:

- Add pipeline compile metrics first.
- Prewarm common pipelines during asset load or decoder creation.
- Audit the existing `ProgramInfo::getProgram()` and `context->globalCache()` behavior first.
- Extend the existing program/global cache only where the current keys or lifetimes are insufficient.
- Avoid adding a parallel descriptor cache unless profiling proves the existing cache cannot cover the
  Metal pipeline miss path.
- Investigate offline or persistent Metal library generation for common runtime shaders.

Expected benefit:

- Lower first-frame and complex-filter p95.
- Better stability for cases like `4.pag`, `9.pag`, `14.pag`, `15.pag`, `16.pag`, and `19.pag`.

Risks:

- Incomplete cache keys can cause incorrect rendering.
- Prewarming too much can increase load time and memory.

Validation:

- `pipeline_compile_us` is zero for steady-state frames.
- First-loop p95 improves without large asset-load regression.

## Recommended Execution Order

1. Implement Phase 0 metrics.
2. Implement Phase 1 churn reduction as a safe short-term improvement.
3. Implement Phase 4 shared Metal resource lifetime as a foundation for the later phases.
4. Implement Phase 2 Metal-native `PAGImageView` playback. This is the main performance unlock.
5. Implement Phase 5 pipeline prewarming for remaining first-frame and complex-effect long tails.
6. Implement Phase 3 if offscreen GPU consumers are a product requirement.

## Acceptance Criteria

The Metal branch should be considered meaningfully optimized only when all of the following are true
on the same iPhone13,2 device and the same `list/0.pag` through `list/19.pag` assets:

- Normal 20-view playback no longer converts every rendered frame to `UIImage`.
- Normal 20-view playback no longer blocks on GPU completion per rendered frame unless explicitly
  taking a snapshot or exporting CPU pixels.
- Snapshot, export, and current-image APIs are allowed to use the slower CPU readback path, but logs
  must distinguish those operations from normal playback frames.
- Metal true-render frame median is at or below OpenGL's median from the baseline run.
- Metal true-render p95 is at or below OpenGL's p95 from the baseline run.
- Frame-0 and first-loop p95 are separately reported and improved.
- Visual output matches the current `PAGImageView` behavior.

Baseline from the 2026-07-03 logs:

| Metric | OpenGL Target |
| --- | ---: |
| True render median | 16.37 ms |
| True render p95 | 37.69 ms |
| Overall frame p95 | 34.62 ms |

## Final Position

Metal is not losing because iOS Metal is inherently slower than OpenGL. It is losing because the
current measured path uses Metal in a CPU-synchronized, offscreen-to-UIImage architecture. To make
Metal win, the normal playback path must become GPU-native: render to reusable Metal resources and
present directly, while keeping CPU pixel extraction as an explicit slow path.
