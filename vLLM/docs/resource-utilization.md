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
6. **(NEW, opened by Run 002) First-concurrent-batch transient.** The first time vLLM sees a request batch larger than any it has serviced this session, it does ~5–7 GiB of allocation/release work over ~25 s, *before* `running` reflects the new batch size. We don't know which subsystem (flashinfer JIT, marlin autotune, cudagraph re-capture, scheduler workspace, …). We don't know if it recurs after long idle periods or only on the first hit per container lifetime. We don't know if pre-warming with a synthetic concurrent batch eliminates it. **This is the binding constraint that blocks every promotion candidate above `4 × 48K`.**
7. **(NEW)** vLLM `Available KV cache memory` is **not deterministic across cold starts** of the same image with the same `.env`. Run 001 → 8.93 GiB, Run 002 → 9.91 GiB. Need to understand what other GPU-resident state changes between starts and whether the variance is bounded.

## Next steps (post Run 002)

The Run 002 verdict (KILLED on a previously unmeasured operating point) reframes everything downstream. Three things to think about, in roughly increasing risk order:

### 1. Characterize the first-concurrent-batch transient before any more load tests

The transient is a *new* signal. We don't know yet whether it is:

- **One-shot per container lifetime** — pay it once on the first batch, never again. If so: pre-warm the engine with a synthetic 4-concurrent batch immediately after the health check passes, then the actual load test runs against an already-warmed engine and never hits the spike.
- **Recurring after idle** — vLLM evicts something during idle and re-allocates on the next batch. If so: any production deployment that has bursty traffic will keep paying the tax, and we have to budget the cap with the transient *included*.
- **A function of batch composition** — only triggered when batch *shape* changes (e.g. mixed prefill/decode), not raw concurrency. If so: a steady-state workload with stable shape would never see it.

Cheapest experiment: against the **currently warm container**, run the same `/tmp/run_002_load_test.py --phase A --pool-gib 9.91` with the kill switch in place. If the transient does *not* recur, that strongly supports the one-shot hypothesis. Total cost: ~5 minutes of GPU time, no config change.

Second experiment: read the docker logs in the spike window (`docker logs docker-vllm-1 --since 21:32:00 --until 21:32:30 2>&1 | grep -iE 'autotune|jit|cudagraph|workspace|alloc'`) to find vLLM init messages that correlate with the 6 GiB swing. May identify the subsystem responsible.

Third experiment: a synthetic pre-warm step in the driver (one quiet 4-concurrent batch with very small `max_tokens`) before the real Phase A. If the spike happens during the pre-warm and not during Phase A, that's the working pattern.

### 2. Decide whether 80 GiB is a hard or soft cap *for transients*

The four-decisions table for Run 002 said the 80 GiB cap is a **soft line** — "steady-state ceiling, profile-pass transients can briefly approach it". Run 002's 80.79 GiB peak respected the *spirit* of that decision (it was a transient, it lasted < 10 s, the swap criterion was untouched). The kill switch tripped because the *driver* threshold (78 GiB, the 2 GiB margin) interpreted any peak above 78 as fatal.

There are two coherent positions:

- **(a) Driver threshold is right.** 78 GiB is the line; any peak above it is a kill, and the next iteration of the harness must drop config to keep the transient under 78. This forces every promotion to leave 2 GiB of headroom even for one-shot transients. Conservative.
- **(b) Driver threshold is wrong for transients.** Distinguish "sustained > 78 for > 5 s" (real OOM risk) from "single-sample peak above 78" (probably one-shot, harmless). Re-instrument the kill switch with a sustained-window check. Permissive.

Option (a) preserves the original safety promise. Option (b) admits that the 80 GiB cap is a *steady-state* number and asks the kill switch to enforce that interpretation.

### 3. Promotion to higher-utility cells

Until items 1 and 2 are resolved, **all candidates above 4 × 48K are blocked** by the corrected matrix + transient caveat. Specifically:

- 4 × 64K is now ❌ with the caveat applied (was ✅ pre-Run-002). Was the original Run 003 target. Cannot proceed.
- 2 × 128K same.
- 1 × 262K survives because at concurrency 1 there is no "first-concurrent-batch" event to trigger the transient. **This is a viable next run** and would give us a hard upper bound on context with no concurrency tradeoff. Worth doing as a sanity check on the model at the high-context end.

A reasonable sequence going forward:

1. **Run 002b**: re-run the same harness against the *warm* container (5 min, no config change) → tests the one-shot hypothesis
2. **Investigate logs** in parallel → identifies the subsystem
3. If 002b passes: **Run 002 (real)** → completes the high-fill characterization that was the original goal
4. **Run 004**: 1 × 262K → proves the high-context-low-concurrency end of the matrix
5. **Run 003 reconsidered**: 4 × 64K only after we know the transient cost, with a pre-warm step in the driver

### 4. The doc itself

This document is now in a state where the *historical* sections (pre-Run-001 model, original matrix, old sensitivity table) sit above a *current* section (calibrated model, calibrated matrix, Run 002 caveat) with explicit SUPERSEDED banners. That's deliberate — the gap between what we believed before measuring and what we now know is itself the most useful artifact for the next run's planning. Don't collapse them.

When Run 002b lands and the transient is characterized one way or the other, this section should be updated with the new findings, the SUPERSEDED banners on older content can be expanded to point at the *new* current section, and the matrix should grow another column showing "with first-concurrent-batch tax included".

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
- `/home/steve/.claude/plans/woolly-dreaming-wave.md` — original NVFP4 harness code-change plan
- `/tmp/run_002_load_test.py` — Run 002 driver (stdlib-only load harness)
- `/tmp/run_002_driver.log` — Run 002 stdout (KILLED summary)
- `/tmp/run_002_turns.csv` — Run 002 per-turn results (4 rows; only Phase A turn 0 ran)
- `/tmp/run_002_memtrail.csv` — Run 002 monitor samples (26 rows; the smoking-gun memory trail)
- HF model card: https://huggingface.co/saricles/Qwen3-Coder-Next-NVFP4-GB10
