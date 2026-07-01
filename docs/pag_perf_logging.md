# PAG Metal Performance Logging

Schema **v2** records frame-level PAG rendering metrics to JSONL. The Metal branch hardcodes
`backend=metal` in `PAGPerfRunner.mm`; use the pre-Metal branch for the OpenGL baseline log.

## What To Compare

| Goal | `PAG_PERF_TARGET` | Primary field |
|------|-------------------|---------------|
| GPU backend A/B (recommended) | `offscreen` (default) | `draw_us` and `flush_us` |
| Real app layer path | `layer` | `flush_us` (includes compositor present) |

**Do not** use schema v1 fields `render_us` / `present_us` / `wall_us`. They mapped to misleading
PAGPlayer buckets (`prepareInternal` vs entire `draw()`).

Schema v2 fields:

- `flush_us` — wall clock around `setProgress` + one `flush()`
- `prepare_us` — `PAGPlayer::prepareInternal()` time (stage/graph build)
- `draw_us` — `PAGSurface::draw()` time (GPU record, submit, and layer present when applicable)
- `image_decode_us` — sequence/video decode time reported by PAGPlayer

For Metal vs OpenGL comparisons, prefer **`draw_us` on `render_target=offscreen`** because it
removes `CAMetalLayer` / `CAEAGLLayer` present pacing that otherwise dominates `flush_us`.

## Enable

Debug builds run the benchmark by default. Set `PAG_PERF_RUN=0` to skip collection.

Output path (default):

```text
Documents/PAGPerf/pag_perf_metal_offscreen_<device>_<timestamp>.jsonl
Documents/PAGPerf/pag_perf_metal_layer_<device>_<timestamp>.jsonl
```

Console:

```text
[PAGPerf] benchmark started: <path> (target=offscreen)
[PAGPerf] benchmark finished: <path>
```

## Optional Settings

```text
PAG_PERF_TARGET=offscreen          # offscreen (default) or layer
PAG_PERF_CASES=alpha.pag,particle_video.pag
PAG_PERF_RUNS=5
PAG_PERF_WARMUPS=3
PAG_PERF_MAX_FRAMES=180
PAG_PERF_FRAME_BATCH=30           # offscreen default 30, layer default 1
PAG_PERF_LOG_FLUSH_FRAMES=120     # buffered writes; no per-frame disk sync
PAG_PERF_STEP_DELAY_MS=0
PAG_PERF_OUTPUT=/path/to/log.jsonl
```

`offscreen` uses `PAGPlayer` + `PAGSurface MakeOffscreen` on a dedicated benchmark queue, so the
UI thread is not blocked. Log writes are buffered on a background I/O queue and only synced at the
end of the run (plus occasional non-synced flushes).

`layer` uses `PAGView` + `CAMetalLayer` on the main thread and needs the host view attached to a
window before `surface_ready`. Logging is still asynchronous, but rendering itself runs on main.

## Start / Frame Events

`start` and `context_ready` include runtime verification fields:

```text
render_target, gpu_name, layer_class (layer mode only)
```

Each `frame` line includes `schema=2`, `render_target`, `gpu_name`, timing fields, and references
case metadata from `context_ready` / `run_start` (device, thermal, width/height are not repeated per
frame).

Stage events: `case_start`, `load_ok`, `context_ready`, `surface_ready`, `surface_timeout`,
`run_start`, `run_done`, `case_done`, `done`.

Benchmark collection starts from `viewDidAppear` for the layer target. Offscreen mode still starts
from the same hook but does not wait on window attachment.
