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
| **Hard cap on projected peak** | **70 GiB** — leaves usable headroom and does not push the host into thrash |

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

### Run 001 — 4 × 48K baseline (planned)

| Field | Value |
|---|---|
| Date | 2026-04-12 |
| Image | `avarok/dgx-vllm-nvfp4-kernel:v23` |
| `max_num_seqs` | 4 |
| `max_model_len` | 49152 |
| Chosen `gpu_memory_utilization` | 0.46 |
| Projected peak (at 0.46) | 67.38 GiB |
| Observed steady-state peak | _pending_ |
| Observed peak during 4-concurrent stress | _pending_ |
| Deviation from projection | _pending_ |
| Notes | Calibration baseline. Picked to survive an overhead estimate error of up to ~2 GiB. Goal: measure actual peak so we can decide whether 4×64K / 2×128K / 5×48K are safe to attempt next. |
| Status | _pending_ |

### Planned follow-up runs (queued, do not execute until Run 001 data is in)

- Run 002 candidate: `4 × 64K` at util ≈ 0.48 — proves both user floors if overhead is ≤ 6 GiB.
- Run 003 candidate: `2 × 128K` at util ≈ 0.48 — proves context-first mode at low concurrency.
- Run 004 candidate: `1 × 262K` at util ≈ 0.48 — proves native max context at single-session.

Each candidate needs Run 001's observed peak to calibrate the overhead constant before attempting.

## Known uncertainties (tracked across runs)

1. **Overhead constant (~6 GiB)** is not empirically pinned on this host. Range 4–8 GiB is plausible. Run 001 should narrow this to ±1 GiB.
2. **KV rate (48 KiB/tok)** was derived from aggregate numbers in the model card, not a direct measurement on this host. May have a small per-session base cost beyond the linear model.
3. **Prefix cache slack** — vLLM will grab extra KV pool within the util budget for prefix caching. If the workload repeatedly hits long shared prefixes (likely for coding), prefix cache can dominate. Measure effective pool usage, not just the configured pool.
4. **Swap interaction** — the host already has ~5.7 GiB of pre-existing swap. If peak approaches cap, the kernel may start paging. Watch `free -h` swap column during stress runs.
5. **`--enforce-eager=true`** is currently set for both profiles; disabling it for throughput is a separate experiment. Don't conflate that with resource planning runs.

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

- `/tmp/vllm-nvfp4-continuation.md` — session handoff with full constant derivations
- `/home/steve/.claude/plans/zesty-giggling-crystal.md` — current execution plan (4 × 48K calibration run)
- `/home/steve/.claude/plans/woolly-dreaming-wave.md` — original code-change plan for the NVFP4 harness
- HF model card: https://huggingface.co/saricles/Qwen3-Coder-Next-NVFP4-GB10
