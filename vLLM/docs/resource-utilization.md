# Resource Utilization — Qwen3-Coder-Next NVFP4 on GB10

Working document. Captures the memory model, the config matrix, and a calibration log that grows as we run experiments. **Append new observations here after each run** rather than starting over.

---

## Host

| Field | Value |
|---|---|
| Machine | sfspark1 (NVIDIA GB10, Grace Blackwell ARM64) |
| Total memory | 128 GiB nominal LPDDR5x (unified, no separate VRAM) |
| Usable memory (`free -h`) | ~121 GiB — kernel/firmware reserve the delta |
| CUDA / driver | 13.0 / 580.126.09 |
| Compute capability | SM 12.1 |
| Ambient non-vLLM processes | ~8.5 GiB (OS + GNOME + **STT service PID 1076583 holding 3.5 GiB — do not touch**) |
| Pre-existing swap usage | ~5.7 GiB (not caused by us) |
| **Hard cap on projected peak** | **80 GiB** (raised from 70 GiB mid-Run-001 on 2026-04-12 — see calibration log) |

`nvidia-smi` reports `Memory-Usage: Not Supported` on GB10 because the GPU and CPU share the same physical memory. Use `free -m` for peak measurement, not `nvidia-smi --query-gpu=memory.used`.

## Model & stack

| Field | Value |
|---|---|
| Model ID | `saricles/Qwen3-Coder-Next-NVFP4-GB10` |
| Base | Qwen3-Next 79.7B MoE (hybrid **DeltaNet + attention**; 10 active experts of 512; 3B active params/token) |
| Quantization | NVFP4 via llm-compressor, stored as `compressed-tensors` |
| Weights on disk | 43 GiB (10 safetensors shards) |
| Weights loaded in CUDA | 44 GiB (observed) |
| Native max context | 262144 tokens |
| Image | `avarok/dgx-vllm-nvfp4-kernel:v23` — vLLM `0.16.0rc2.dev236+g3b30e6150.d20260221`, CUDA 13.0 |
| KV cache dtype | `fp8` (via `--kv-cache-dtype fp8`) |
| Attention backend | Flashinfer (via `--attention-backend flashinfer`) |
| NVFP4 GEMM backend | Marlin (via `VLLM_NVFP4_GEMM_BACKEND=marlin`) |
| Required container env | `VLLM_NVFP4_GEMM_BACKEND=marlin`, `VLLM_TEST_FORCE_FP8_MARLIN=1`, `VLLM_USE_FLASHINFER_MOE_FP4=0`, `VLLM_MARLIN_USE_ATOMIC_ADD=1` |

## Memory model (the math used for planning)

> **SUPERSEDED 2026-04-12.** This section is the *pre-Run-001* planning model. Run 001 measurements falsified its specific coefficients (it underestimated overhead by ~7 GiB). Run 002 then exposed an entirely new operating point (a first-concurrent-batch transient) that no version of this static model captures. **For current numbers, see "Calibrated model (Run 001 corrected) and post-Run-002 caveats" further down.** The section is preserved as a historical artifact — it is what we believed *before* taking measurements, and the gap between belief and measurement is itself useful data.

**Components of peak system memory:**

```
Peak = Ambient + vLLM_process_footprint
     = Ambient + Weights + Python/Framework_overhead + Activations/Workspace + KV_pool
```

Measured / estimated constants:

| Component | Value | Source |
|---|---|---|
| Weights resident in CUDA | 43 GiB | observed via `nvidia-smi` during previous run |
| Python/framework overhead | ~2 GiB | gap between weights-in-CUDA and container RSS |
| Activations/workspace (MoE + Flashinfer + 8K prefill buffer) | ~4 GiB | estimated, **not yet empirically pinned** |
| Fixed vLLM overhead | **~49 GiB** | 43 + 2 + 4 |
| Ambient non-vLLM | 8.5 GiB | measured on sfspark1 |
| **Baseline before KV** | **~57.5 GiB** | fixed + ambient |

**KV cache rate:** `48 KiB/token` with `--kv-cache-dtype fp8`. Derived from the HF README's reported `61.7 GiB / 1,346,432 tokens = 49,203 bytes/token ≈ 48 KiB`. This number already amortizes the DeltaNet Mamba recurrent state and vLLM's block rounding.

**vLLM block size quirk:** on Qwen3-Next, vLLM enforces `attention_block_size >= mamba_page_size` and sets attention block size to **1072 tokens** regardless of `--block-size`. Every session pays a minimum of 1 block × 1072 × 48 KiB ≈ **52 MB KV floor**. Ignorable at ≥10K context; dominant at <1K.

**Formulas (for any (seqs, ctx) cell):**

```
total_K_tokens      = max_num_seqs × (max_model_len / 1024)
KV_GiB              = total_K_tokens × 0.046875          # 48 KiB/tok → 48/1024 GiB per 1K tok
Required util (min) = (49 + KV_GiB) / 128                # fits workload exactly
Chosen util         = required + small slack             # typically +0.005 to +0.02
Projected peak      = chosen_util × 128 + 8.5            # vLLM footprint + ambient
Fits cap            = Projected peak ≤ 70 GiB  ⟺  chosen_util ≤ 0.480
```

Note: `gpu_memory_utilization` is the vLLM process's ceiling, not a target. Setting it higher than required gives vLLM more KV pool (prefix cache slack), which raises actual peak. Tune it tight.

## The peak-memory matrix (projected, at minimum util)

> **SUPERSEDED 2026-04-12.** This matrix uses the pre-Run-001 model and the old 70 GiB cap. See "Calibrated model" section below for the post-Run-001 matrix at the 80 GiB cap, and the Run 002 caveat about the first-concurrent-batch transient that may make even the corrected matrix optimistic.

Cell value = projected peak GiB at `util = required_min`. Legend: ✅ comfortable (≥4 GiB under cap) · ⚠ RISKY (<4 GiB headroom — within overhead slop) · ❌ over cap.

| seqs ↓ / ctx → | **32K** | **48K** | **64K** | **96K** | **128K** | **192K** | **262K** |
|---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **1** | 59.0 ✅ | 59.75 ✅ | 60.5 ✅ | 62.0 ✅ | 63.5 ✅ | 66.5 ✅ | 69.79 ⚠ |
| **2** | 60.5 ✅ | 62.0 ✅ | 63.5 ✅ | 66.5 ✅ | 69.5 ⚠ | 75.5 ❌ | 82.08 ❌ |
| **3** | 62.0 ✅ | 64.25 ✅ | 66.5 ✅ | 71.0 ❌ | 75.5 ❌ | — ❌ | — ❌ |
| **4** | 63.5 ✅ | 66.5 ✅ | 69.5 ⚠ | 75.5 ❌ | 81.5 ❌ | — ❌ | — ❌ |
| **5** | 65.0 ✅ | 68.75 ⚠ | 72.5 ❌ | — ❌ | — ❌ | — ❌ | — ❌ |
| **6** | 66.5 ✅ | 71.0 ❌ | — ❌ | — ❌ | — ❌ | — ❌ | — ❌ |

### Minimum required `gpu_memory_utilization`

| seqs ↓ / ctx → | 32K | 48K | 64K | 96K | 128K | 192K | 262K |
|---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **1** | 0.395 | 0.401 | 0.406 | 0.418 | 0.430 | 0.453 | 0.479 |
| **2** | 0.406 | 0.418 | 0.430 | 0.453 | 0.477 | — | — |
| **3** | 0.418 | 0.436 | 0.453 | — | — | — | — |
| **4** | 0.430 | 0.453 | 0.477 | — | — | — | — |
| **5** | 0.441 | 0.471 | — | — | — | — | — |
| **6** | 0.453 | — | — | — | — | — | — |

### Sensitivity — what breaks if overhead is 2 GiB higher than estimated

| Config | Peak @ 6 GiB overhead | Peak @ 8 GiB overhead | Verdict |
|---|---:|---:|---|
| 4 × 64K | 69.5 | **71.5 ❌** | risky config fails |
| 2 × 128K | 69.5 | **71.5 ❌** | risky config fails |
| 5 × 48K | 68.75 | **70.75 ❌** | risky config fails |
| 1 × 262K | 69.79 | **71.79 ❌** | risky config fails |
| 4 × 48K | 66.5 | 68.5 ✅ | safe under slop |
| 3 × 64K | 66.5 | 68.5 ✅ | safe under slop |
| 1 × 128K | 63.5 | 65.5 ✅ | safe under slop |

Until we pin the actual overhead empirically, **prefer ✅ configs**. The point of the calibration runs below is to shrink this uncertainty band.

## Usage goals (what we are actually trying to serve)

- **Coding workloads** — context matters, 32K is too small to be useful.
- **Concurrency floor:** ≥ 4 simultaneous sessions (user-explicit minimum).
- **Context goal:** 128K per session if achievable while keeping the concurrency floor.
- **Priority order:** large context > high concurrency.

The matrix above shows that **no cell simultaneously satisfies ≥4 sessions AND ≥64K context under the ✅ (safe) band**. The only cell meeting both floors is `4 × 64K`, which is ⚠ risky. This is the core tension we are measuring our way out of.

## Calibration log

Append one entry per run. Each entry should include the config, the observed peak, and the deviation from the model's projection. These numbers are what let us tighten the overhead constant and eventually unlock the ⚠ configs with confidence.

### Run 001 — 4 × 48K baseline

| Field | Value |
|---|---|
| Date | 2026-04-12 |
| Image | `avarok/dgx-vllm-nvfp4-kernel:v23` |
| `max_num_seqs` | 4 |
| `max_model_len` | 49152 |
| Chosen `gpu_memory_utilization` | 0.46 |
| Projected peak (pre-Run-001 model, at 0.46) | 67.38 GiB |
| **Observed Available KV cache memory** | **8.93 GiB** (vLLM `gpu_worker.py` log line) |
| **Observed peak at health-pass** | **66.3 GiB** |
| **Observed steady serving (post-profile)** | **69.9 GiB** |
| **Observed profile-pass transient (~20 s)** | **72.9 GiB** ← binding constraint |
| Burst test (4-parallel, 2000 tokens each) | 88 s wall, ~91 tok/s aggregate, 100 % success |
| Burst test KV pool peak | **2.8 %** |
| Cap raised mid-session | **70 → 80 GiB** (because pre-Run-001 model under-projected by ~7 GiB and 70 was tighter than necessary on real numbers) |
| Status | **PASS — but limited.** Smoke test and 4-parallel burst both succeeded. KV pool was driven to only 2.8 %, so high-fill behavior was *not* characterized. That gap is what Run 002 was designed to fill. |
| Notes | The pre-Run-001 model was wrong by ~7 GiB. The corrected three-coefficient model (peak_health / peak_steady / peak_profile = 57.4 / 61.0 / 64.0 + pool) was derived from this run and is documented in "Calibrated model" below. |

### Calibrated model (Run 001 corrected) and post-Run-002 caveats

**This is the model we use for planning now.** It supersedes the static `Ambient + Weights + Workspace + KV` decomposition above.

```
pool_GiB     = max_num_seqs × max_model_len × 48 KiB / 1024²

peak_health  ≈ 57.4 + pool_GiB    # the moment health check first passes
peak_steady  ≈ 61.0 + pool_GiB    # post profile-pass quiescent serving
peak_profile ≈ 64.0 + pool_GiB    # the ~20 s transient during the post-startup profile pass
```

All three constants were validated against `free -m` measurements during Run 001 to within 0.1 GiB. The relationship `peak_steady - peak_health ≈ 3.6 GiB` is the cuda-cache pinning that survives the profile pass; `peak_profile - peak_steady ≈ 3 GiB` is the worst-case batch the profile pass pushes through the model on every container start.

> **POST-RUN-002 CAVEAT (CRITICAL).** Run 002 measured a *new* operating point that none of the three coefficients above describes: a **first-concurrent-batch initialization transient** of roughly +5 to +7 GiB above `peak_steady`, occurring asynchronously during the first ~25 s after the engine sees a request batch larger than any it has serviced before. It is *not* the post-startup profile pass — that happens during container init, before the API server is up. It is *not* tied to active inference — Run 002 saw the spike with `running=0`. And it is not yet pinned to a specific vLLM subsystem. Until characterized, **add 5–7 GiB to `peak_steady` for any (seqs, ctx) cell that has never been exercised at full concurrency on the running engine**, and treat that as a new binding constraint above `peak_profile`.

**Calibrated peak-memory matrix at 80 GiB cap (uses corrected `peak_profile = 64 + pool`).** Cell value = projected GiB. Legend: ✅ ≥3 GiB headroom · ⚠ 1–3 GiB · ❌ over cap. **None of these cells include the first-concurrent-batch tax** — see caveat above.

| seqs ↓ / ctx → | 32K | 48K | 64K | 96K | 128K | 192K | 262K |
|---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | 65.5 ✅ | 66.3 ✅ | 67.0 ✅ | 68.5 ✅ | 70.0 ✅ | 73.0 ✅ | 76.3 ✅ |
| 2 | 67.0 ✅ | 68.5 ✅ | 70.0 ✅ | 73.0 ✅ | 76.0 ✅ | 82.0 ❌ | 88.6 ❌ |
| 3 | 68.5 ✅ | 70.75 ✅ | 73.0 ✅ | 77.5 ⚠ | 82.0 ❌ | — | — |
| **4** | 70.0 ✅ | **73.0 ✅** *(Run 001)* | **76.0 ✅** *(was Run 003 target)* | 82.0 ❌ | 88.0 ❌ | — | — |
| 5 | 71.5 ✅ | 75.25 ⚠ | 79.0 ⚠ | — | — | — | — |
| 6 | 73.0 ✅ | 77.5 ⚠ | 82.0 ❌ | — | — | — | — |

**With the Run 002 caveat applied** (add ~7 GiB for any cell that hasn't been exercised at concurrency on a warm engine), several cells previously called ✅ become ⚠ or ❌:

| Cell | Without caveat | With +7 GiB cold-start tax | New verdict |
|---|---:|---:|:---:|
| 4 × 48K | 73.0 | 80.0 | ⚠ at the cap |
| 4 × 64K | 76.0 | 83.0 | ❌ |
| 2 × 96K | 73.0 | 80.0 | ⚠ at the cap |
| 1 × 128K | 70.0 | 77.0 | ⚠ |

This is the central finding from Run 002: **the model that promised 4 GiB of headroom for the original Run 003 target (4 × 64K) was structurally optimistic**, because it didn't know about a transient operating point that lives above its highest coefficient.

### Run 002 — 4 × 48K under load (KILLED)

| Field | Value |
|---|---|
| Date | 2026-04-12 |
| Container state | Restarted from cold (Run 001 container had been removed) |
| Config | Identical to Run 001 — `max_num_seqs=4`, `max_model_len=49152`, `gpu_memory_utilization=0.46`, image `avarok/dgx-vllm-nvfp4-kernel:v23` |
| **Observed Available KV cache memory** | **9.91 GiB** (Run 001 was 8.93 — 1 GiB more pool, presumably 1 GiB less compute workspace) |
| Plan | Three escalating phases A→B→C in one container lifetime (4×4×1500, 4×10×2000, 4×16×2500 max_tokens), full observability, kill switch at 78 GiB / +1.5 swap / 95 % KV |
| Driver | `/tmp/run_002_load_test.py` (stdlib only, 4 worker threads + 2 s monitor + kill switch) |
| **Verdict** | **KILLED on criterion #2** — peak host used 80.79 GiB > 78 GiB |
| **Turns completed** | 4 of 120 (Phase A turn 0 only; phases B and C never started) |
| Per-turn errors | **0** — every request that ran completed successfully (~57.9 s wall each, 1500 tokens, KV peak 2.5 %) |
| Peak host used | **80.79 GiB** |
| Peak swap | 10.00 GiB (+0.17 vs driver baseline of 9.83) — criterion #3 **PASS** |
| Peak KV pool | 2.5 % — criterion #5 **PASS** |
| Latency drift | insufficient data — criterion #4 N/A |
| Observed vs projection | Δ +9.88 GiB above `peak_steady` — criterion #6 **FAIL** |

**The smoking-gun memtrail** (`/tmp/run_002_memtrail.csv`, abbreviated):

```
21:32:02  used=75.24 GiB  swap=9.81  kv=0.0%  run=0    ← driver baseline
21:32:05  used=76.58       9.75      0.0      0
21:32:07  used=79.70       9.68      0.0      0    ← oscillation, no requests
21:32:09  used=80.29       9.85      0.0      0
21:32:11  used=75.31       10.00     0.0      0
21:32:13  used=75.43       9.71      0.0      0    ← container_rss jumps 280→646 MiB
21:32:17  used=80.79       9.67      0.0      0    ← PEAK, still no requests
21:32:19  used=80.26       9.64      0.0      0
21:32:23  used=76.07       9.64      0.0      0
21:32:25  used=76.06       9.63      0.0      0
21:32:29  used=77.43       9.63      2.0      4    ← workers active at last
21:32:31  used=79.16       9.62      2.0      4
21:32:42  used=68.34       9.39      2.0      4    ← drops 13 GiB mid-flight
21:32:45  used=66.06       9.29      2.0      4
21:33:00  used=65.86       9.26      2.5      4    ← steady state under 4-concurrent inference
```

**The peak occurred while `running=0`** — *before any worker had successfully sent a request*. Memory oscillated wildly between 75 and 81 GiB during the 24 s the workers were inside `urlopen()` waiting for vLLM to schedule the requests. By the time `running=4` finally appeared, the spike was already over and memory was trending down. Once the engine was actually serving 4 concurrent requests, memory dropped to ~66 GiB and stayed there.

Container RSS jumped 280 → 646 → 556 MiB across the same window, confirming the allocation activity was happening *inside* the vLLM process before it picked up the request batch.

**Hypothesis (`[inferred]`, not yet verified):** vLLM (flashinfer JIT? marlin kernel autotune? cudagraph re-capture for new batch shapes?) does ~5–7 GiB of allocation/release work the *first time* it sees N concurrent requests where N exceeds the largest batch it has serviced this session. The dry-run that preceded the main run only sent `running=1`, so the `running=4` codepath was cold. Run 001's burst test didn't catch this either — that test ran on a freshly-warmed engine where the post-startup profile pass had already touched batch sizes including 4 (per `cudagraph_capture_sizes: [1, 2, 4, 8]`).

**Other notable measurements from Run 002:**

- **Active inference at low fill (4 concurrent reqs, 2.5 % KV) used ~66 GiB** — *lower* than the corrected `peak_steady` projection of 70.91 GiB. Once warm, the engine is actually more memory-efficient than the model says.
- The driver's own baseline at run start (75.06 GiB) was already 7 GiB above the dry-run baseline (67.66 GiB), captured ~75 s earlier. Whatever consumed those 7 GiB happened in that gap, with no driver activity. Either vLLM's idle background work allocated, or the kernel's unified-memory accounting has lag.
- `Available KV cache memory` was 9.91 GiB (vs Run 001's 8.93 GiB) under identical config. That's a +1 GiB shift in pool size between two cold starts of the same image. We don't know what GPU resident state changed between the two runs to explain it.

**Artifacts:** `/tmp/run_002_load_test.py`, `/tmp/run_002_driver.log`, `/tmp/run_002_turns.csv` (4 rows), `/tmp/run_002_memtrail.csv` (26 samples).

### Run 002b — Sequential warmup characterization (PASS, outcome refined)

| Field | Value |
|---|---|
| Date | 2026-04-12 |
| Container state | Cold start (fresh `docker compose up -d` after Run 002 cleanup) |
| Config | Identical to Runs 001/002 — `max_num_seqs=4`, `max_model_len=49152`, `gpu_memory_utilization=0.46`, image v23 |
| Pool size | **9.72 GiB** (Run 001: 8.93, Run 002: 9.91, Run 002b: 9.72 — keeps drifting cold-start to cold-start) |
| Test shape | 4 sequential single-threaded requests, distinct topics, max_tokens=1500, 30 s idle gaps, streaming so we capture TTFT |
| Cap raised | 80 → 90 GiB for this run; kill switch 88 GiB |
| Driver | `vLLM/scripts/run_002b_sequential.py` (committed `630ec8a`) |
| Verdict | **PASS — outcome D in the static framework, but the TTFT progression refines the diagnosis** |

**The headline finding — TTFT progression:**

| # | Topic | TTFT (s) | Wall (s) | Tokens out | Peak GiB during request |
|---|---|---:|---:|---:|---:|
| 1 | Rust | **33.19** | 57.21 | 1500 | 68.02 |
| 2 | Postgres | **0.31** | 23.95 | 1500 | 67.93 |
| 3 | Linear algebra | **0.13** | 23.89 | 1500 | 67.96 |
| 4 | Distributed systems | **0.10** | 23.72 | 1500 | 67.96 |

Request 1 paid **33 seconds of first-token latency**. Requests 2–4 paid **~0.1–0.3 s**. That is a 100–330× speedup, and it is rock-solid evidence that vLLM does **once-per-engine-lifetime JIT-compile work** on the first real request — *separately* from the post-startup profile pass that happens during `docker compose up -d`. The four prompts were on completely different topics specifically to defeat the prefix cache, so the speedup cannot be explained by prefix-cache hits.

**The memory finding — flat as a board:**

| Phase | Used (GiB) |
|---|---:|
| Cold idle (60 s before first request) | 67.24 |
| Peak during request 1 | 68.02 |
| Peak during requests 2–4 | 67.93–67.96 |
| Warm tail (60 s after last request) | 67.97 |
| **Total memory swing across the entire 7-minute run** | **~1.1 GiB** |

The kill switch never approached its 88 GiB threshold (~20 GiB margin throughout). Compare to Run 002, which oscillated between 75 and 81 GiB over a 25-second window with `running=0` and tripped the kill switch *before any worker had successfully sent a request*.

**Together these two findings reframe the Run 002 spike entirely.** Run 002b proves that:

1. **JIT compile work exists** (the 33 s TTFT on req 1) but **does not allocate significant resident memory**. Whatever vLLM JITs on the first request fits inside the workspace already pre-allocated at startup. So a "pre-warm with one dummy request" strategy fixes TTFT for the first real user but does **not** fix the Run 002 memory spike — they're different problems.
2. **The Run 002 memory spike is therefore concurrency-specific**, not coldness-specific. Sequential cold requests don't trigger it; 4 simultaneous requests do. The likely cause is something on the chunked-prefill / parallel scheduler / multi-batch-attention codepath that allocates buffers only when the batch arrives in parallel.
3. **The corrected `peak_steady` coefficient is itself slightly too high.** Run 001 measured `peak_steady = 69.9 GiB` at pool 8.93 → const ≈ 61.0. Run 002b measured `peak_steady = 68.02 GiB` at pool 9.72 → const ≈ 58.3. That's a **~3 GiB downward revision** of the model's static coefficient. We'd informally read it as `peak_steady ≈ 58.3 + pool_GiB` going forward, but only one data point is not enough to commit a new constant. Track it, re-test on the next run.

**What this does NOT prove**

Run 002b sent requests one at a time, so it never exercised any concurrency codepath. It has therefore not measured what happens on a *concurrent* batch — only that *sequential* batches are well-behaved. The Run 002 spike is still not explained, only narrowed: it lives somewhere in the concurrent codepath, not in the cold-engine codepath.

**Updated outcome interpretation**

The plan classified outcomes as A/B/C (per-spike framework) or D (no spike). Run 002b lands in D *for the sequential test* — but D is not really "no spike" in the universal sense, it is "no spike on the sequential codepath." The right name for this outcome is:

> **Outcome E — sequential is fine, the spike is concurrency-bound.**

**Artifacts** (under `vLLM/runs/run_002b/`):
- `run_002b_driver.txt` — full stdout
- `run_002b_per_request.csv` — 9 rows: 4 boundary markers + 4 request rows + 1 warm tail
- `run_002b_memtrail.csv` — 463 samples at ~0.5 s cadence over the full ~7 min window

### Planned follow-up runs (queued, **all blocked** by the Run 002 finding)

- ~~Run 003 candidate: `4 × 64K` at util 0.48~~ — **blocked.** Projected at 76 GiB by the corrected model (4 GiB headroom under the 80 GiB cap). With the +7 GiB first-concurrent-batch tax we now know about, this cell projects to **~83 GiB**, *over* the cap. Cannot promote until the transient is either characterized away or shown to be one-shot per container lifetime *and* we're willing to accept a brief excursion past 80 GiB.
- Run 003 candidate: `2 × 128K` at util ≈ 0.48 — also blocked, but for a different reason: same +7 GiB tax would put it at ~83 GiB.
- Run 004 candidate: `1 × 262K` at util ≈ 0.48 — **only ✅ candidate that survives the caveat** (76.3 + 7 = 83 GiB ❌ at concurrency 1? actually no: 1-session never hits "first-concurrent-batch" because there is no batch >1. So 76.3 GiB is the real number — ✅). Worth doing as an *unconcurrent* bound check.
- A new candidate: **Run 002b — same config, warm engine** — re-run the same A→B→C sequence against the *currently warm* container. If the spike doesn't recur, it confirms first-concurrent-batch is one-shot per container lifetime, and we can pre-warm before any load test.

## Known uncertainties (tracked across runs)

1. ~~**Overhead constant (~6 GiB)** is not empirically pinned on this host.~~ **Resolved by Run 001 (partially):** the static overhead splits into three operating points (`peak_health` / `peak_steady` / `peak_profile` = 57.4 / 61.0 / 64.0 + pool, validated to ±0.1 GiB at one config). **Reopened by Run 002**: a fourth operating point exists (first-concurrent-batch transient) that adds another ~5–7 GiB and is not explained by any of the three static coefficients. See item 6.
2. **KV rate (48 KiB/tok)** was derived from aggregate numbers in the model card, not a direct measurement on this host. Run 001 saw 8.93 GiB pool, Run 002 saw 9.91 GiB pool *under identical config* — a 1 GiB shift between two cold starts of the same image. The KV rate may not be the only thing varying; could also be how vLLM splits the util budget between weights, workspace, and pool depending on what other processes hold GPU resident state at startup.
3. **Prefix cache slack** — vLLM will grab extra KV pool within the util budget for prefix caching. If the workload repeatedly hits long shared prefixes (likely for coding), prefix cache can dominate. **Not yet measured at high fill** — Run 002 was killed before reaching the phase that would have exercised this.
4. **Swap interaction** — the host already has ~5.7 GiB of pre-existing baseline swap. Run 002 saw the driver-start swap baseline at 9.83 GiB (3.6 GiB above the dry-run baseline 50 s earlier — unclear what allocated). Peak swap during the run was +0.17 GiB above baseline, so the kill switch's swap criterion was never triggered. But the *baseline shifting* between runs is itself a flag.
5. **`--enforce-eager=true`** is currently set; disabling for throughput is a separate experiment. Don't conflate with resource planning.
6. **(REFINED by Run 002b) Concurrency-bound memory transient (NOT cold-engine).** Run 002b proved that *sequential* requests against a fresh container are well-behaved (~1 GiB total memory swing across 4 requests, no spike). The Run 002 spike is therefore tied specifically to **concurrent batch arrival**, not to engine coldness or first-request work. The JIT compilation that does happen on the first request (33 s TTFT, see Run 002b) is **memory-free** — it consumes only time, not RAM. So a "pre-warm with one dummy request" strategy fixes TTFT but **does not fix the Run 002 spike**. The next investigation needs a synthetic *concurrent* pre-warm. We still don't know which subsystem (chunked-prefill workspace, parallel scheduler buffers, multi-batch attention/MoE kernels) causes the concurrent allocation, but we now know which codepath to instrument.
7. **(NEW)** vLLM `Available KV cache memory` is **not deterministic across cold starts** of the same image with the same `.env`. Run 001 → 8.93 GiB, Run 002 → 9.91 GiB, Run 002b → 9.72 GiB. ~1 GiB drift across three cold starts. Need to understand what other GPU-resident state changes between starts and whether the variance is bounded.
8. **(NEW, opened by Run 002b)** The corrected `peak_steady` coefficient (61.0) appears **~3 GiB too high**. Run 002b observed peak_steady ≈ 68.02 GiB at pool 9.72 → const ≈ 58.3. Run 001 measured const ≈ 61.0 at pool 8.93. Either Run 001's measurement was contaminated by transient state, or the actual constant varies with pool size in a non-additive way. Track on the next run; do not commit a new constant from one data point.

## Next steps (post Run 002b)

Run 002b refined the understanding considerably. We now know:

- ✅ JIT compile work on the first real request is real (~33 s TTFT) but **memory-free**
- ✅ Sequential requests are well-behaved (~1 GiB total swing) — the kill switch never approached 88
- ✅ The Run 002 spike is **concurrency-bound**, not coldness-bound — it lives somewhere on the parallel-batch codepath, not the cold-engine codepath
- ❓ Which specific subsystem allocates on parallel arrival is still unknown (chunked-prefill workspace? scheduler? multi-batch attention?)
- ❓ Whether a *concurrent* synthetic pre-warm cancels the spike permanently is the next experiment

### Run 002c — concurrent pre-warm test (the next plan)

**Objective:** demonstrate that pre-warming the engine with a synthetic 4-concurrent batch immediately after health-pass eliminates the Run 002 memory spike on subsequent 4-concurrent traffic.

**Shape:**

1. Cold start container, wait for `/health`
2. **Concurrent pre-warm step**: send 4 simultaneous chat requests with `max_tokens=16` (just enough to engage the parallel codepath without using meaningful KV). Capture memory during this. Expectation: a one-shot spike of ~5–7 GiB, releasing back to baseline within ~30 s.
3. **Wait for memory to settle** (60 s observation window)
4. **Run the original Run 002 Phase A** (4 × 4 × 1500): the real concurrent load test. Expectation: no spike, because the pre-warm already paid the concurrency-allocation cost.
5. If Phase A passes cleanly, proceed to Phase B and Phase C — the high-fill characterization that Run 002 was originally designed to do.

**Driver:** new file `vLLM/scripts/run_002c_prewarm.py`, derived from `run_002_load_test.py` with a `pre_warm()` step inserted before the first phase. Reuses Monitor / KillState / parsers verbatim.

**Cap policy for Run 002c:** keep the 90 GiB ceiling, kill switch 88. If the pre-warm spike fits under 80 (the original cap), drop back to 80/78. If it doesn't, we've learned that pre-warm itself needs the extra headroom.

**Success criteria for Run 002c:**
1. Pre-warm spike observed (proof we triggered it deterministically) and resolves before Phase A starts
2. Phase A completes without tripping the kill switch
3. Phase B completes
4. Phase C completes — gives us the high-fill measurements that were the entire point of Run 002

### Run 002d (deferred) — log forensics on the concurrent codepath

If 002c does not eliminate the spike, the next move is to read vLLM source / docker logs around the spike window for whichever subsystem allocates on first parallel arrival. Candidates: `vllm/v1/engine/core.py`, `vllm/attention/backends/flashinfer.py`, chunked-prefill scheduler, marlin MoE first-call autotune. Cheap if 002c works; only needed if it doesn't.

### Other observations to pursue

- **Pool size drift** (item 7 above): three cold starts, three different pool sizes (8.93 / 9.91 / 9.72 GiB). This affects every projection. Worth a small standalone experiment: cold-start the container 5 times, capture the pool size each time. If the variance is bounded (~±1 GiB) we can budget for it; if it's wider, it warrants a config or env investigation.
- **`peak_steady` coefficient revision** (item 8): Run 002b's 58.3 vs Run 001's 61.0 needs a third data point to commit a new constant. Run 002c's Phase B/C steady states will give us that.
- **The 4 × 64K promotion** is still blocked by the corrected matrix with the +7 GiB cold-start tax. After Run 002c characterizes what the *concurrent* spike actually costs (it may be smaller than the +7 GiB scary number we extrapolated from Run 002), the matrix may unblock 4 × 64K with a pre-warm.

### Cap policy

The original 80 GiB hard cap held through Run 001 and Run 002b without ever being touched. Run 002 briefly exceeded it at 80.79 GiB, but that was during a transient our kill switch (correctly) caught. Run 002b ran with 90 GiB lifted ceiling and used at most 68 GiB — so the lifted ceiling was unused observability headroom, exactly as intended.

Going forward, the cap should be interpreted as **"steady-state ceiling, brief transients within headroom are acceptable if the swap criterion stays clean"**. The kill switch encodes the policy. Until Run 002c proves the concurrent spike is well-bounded, keep the kill switch at 88 GiB on any concurrent test.

### The doc itself

After Run 002c lands, this document should be reorganized: the *pre-Run-001* SUPERSEDED sections can probably be archived (moved to a separate `resource-utilization-history.md` or similar) and the calibration log promoted to the top. We've now run enough experiments that the historical planning content is more confusing than useful. Wait until 002c to make that structural change — one more run will produce the final coefficient set.

## Commands used for observation

```bash
# Memory watchdog (sample every 3s, print max over window)
while true; do free -m | awk 'NR==2 {print strftime("%T"), $3}'; sleep 3; done

# Or a bounded one-liner that prints running max
python3 -c 'import subprocess, time, re
peak=0
for _ in range(300):
    out=subprocess.check_output(["free","-m"]).decode()
    used=int(re.findall(r"\d+", out.split("\n")[1])[1])
    peak=max(peak,used)
    print(f"{time.strftime(\"%T\")}  used={used}MiB  peak={peak}MiB", flush=True)
    time.sleep(3)'

# Log tail for backend confirmation
uv run bootstrap-vllm logs --tail 400 | grep -E 'NvFp4|FLASHINFER|MARLIN|fp8|attention block size|max_num_seqs|KV cache'
```

## References

- `/tmp/vllm-nvfp4-continuation.md` — pre-Run-001 session handoff with original constant derivations
- `/tmp/vllm-run-002-continuation.md` — Run 002 session handoff (corrected coefficients, the four open questions, the locked-in decisions)
- `/home/steve/.claude/plans/zesty-giggling-crystal.md` — Run 001 plan (4 × 48K calibration)
- `/home/steve/.claude/plans/twinkly-giggling-eagle.md` — Run 002 plan (load test against 4 × 48K)
- `/home/steve/.claude/plans/greedy-crafting-mochi.md` — Run 002b plan (sequential warmup characterization)
- `/home/steve/.claude/plans/woolly-dreaming-wave.md` — original NVFP4 harness code-change plan
- `vLLM/scripts/run_002_load_test.py` — Run 002 driver (committed `630ec8a`)
- `vLLM/scripts/run_002b_sequential.py` — Run 002b driver (committed `630ec8a`)
- `vLLM/runs/run_002/` — Run 002 artifacts (driver log, turns CSV, memtrail CSV)
- `vLLM/runs/run_002b/` — Run 002b artifacts (driver log, per-request CSV, memtrail CSV)
- HF model card: https://huggingface.co/saricles/Qwen3-Coder-Next-NVFP4-GB10
