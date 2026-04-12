# Claude Session Continuation — vLLM NVFP4 Coder for GB10

**Handoff date:** 2026-04-12
**Previous session CWD:** `/opt/dev/trt`
**New session CWD:** `/opt/dev/aeo/aeo-infra/vLLM` (here)
**Hardware target:** NVIDIA GB10 / DGX Spark (128GB unified LPDDR5x, Blackwell SM120/121)

---

## Why we moved here

We were working in `/opt/dev/trt` (the TRT-LLM OpenAI proxy project, currently serving `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8`). The question was: **has the NVFP4 coding-model landscape shifted enough since January 2026 to justify a move?**

Short answer: **yes** — but the working path is vLLM, not TRT-LLM. This harness already exists, so we're continuing the work here directly.

---

## Key research findings (verified 2026-04-12, via parallel web-search agents)

### The new coder model

**`Qwen/Qwen3-Coder-Next`** — released **2026-02-03** by the Qwen org.
- 80B total / **3B active** (MoE, same A3B lineage as current Qwen3-Coder-30B-A3B)
- 256K native context
- Apache-2.0
- Qwen itself ships BF16 + FP8 + GGUF; **no NVFP4 from Qwen**

### NVFP4 variants (third party)

| HF Path | Source | GB10 status |
|---|---|---|
| **`saricles/Qwen3-Coder-Next-NVFP4-GB10`** | community | **Confirmed working on GB10** — 60-62 tok/s decode, 42.7 GiB model mem, 1.3M tok KV cache |
| `RedHatAI/Qwen3-Coder-Next-NVFP4` | Red Hat | llm-compressor 0.9.0.1, SWE-Bench Lite 52%, no explicit GB10 validation |
| `GadflyII/Qwen3-Coder-Next-NVFP4` | community | Works on sglang but SLOWER than FP8 (BF16 `in_proj_qkvz` bottleneck, ~34 tok/s vs 43 tok/s FP8) |
| `nvidia/Qwen3-Coder-480B-A35B-Instruct-NVFP4` | NVIDIA | 241GB on disk — **too big for GB10** |

**`[observed]`*`[researched]`*** The `saricles/Qwen3-Coder-Next-NVFP4-GB10` quant is the cleanest working story on GB10 today. Benchmarked with llama-benchy 0.3.3.

### Why not TRT-LLM?

**`[observed]`*`[researched]`*** As of 2026-04-12, TRT-LLM has **unmerged** SM120/SM121 NVFP4 MoE fix PRs:
- #12310 (autotuner SM121 bounds check) — OPEN
- #12704 (CUTLASS MoE GEMM tile config filter) — OPEN
- #12705 (CUDA core fast path for SM121) — OPEN
- #11997 (ungate fused MoE for SM120/121) — OPEN

Default CUTLASS path fails with:
- `NotImplementedError: TRTLLMGenFusedMoE does not support SM120 and above`
- CUTLASS SMEM failure (GB10 has 99 KiB/block vs SM100's 228 KiB)

Workaround `TRTLLM_MOE_BACKEND=TRITON` exists (6.7× speedup, undocumented) but TRT-LLM 1.3.0rc7 has been reported failing `trtllm-serve` for Qwen3-Next-80B in **both** NVFP4 and FP8 on GB10.

### Working GB10 NVFP4 stack (confirmed)

```
vLLM:      0.16.0-rc2
Image:     avarok/dgx-vllm-nvfp4-kernel:v23
Backend:   VLLM_NVFP4_GEMM_BACKEND=marlin
CUDA:      13.0
Compute:   SM 12.1
Model:     saricles/Qwen3-Coder-Next-NVFP4-GB10
Result:    60-62 tok/s decode, 42.7 GiB model mem, 1.3M tok KV cache
```

**`[uncertain]`** Whether NGC `nvcr.io/nvidia/vllm:25.12-py3` (what this harness currently uses) ships a new enough vLLM + Marlin NVFP4 backend to serve this model without switching to the `avarok` image. **This needs verification as the first step.**

---

## Current state of THIS harness (`/opt/dev/aeo/aeo-infra/vLLM/`)

**`[observed]`** Last touched **2026-01-25** — predates all the Qwen3-Coder-Next / NVFP4 research. Nothing has been updated since.

### Structure (from PLAN.md + README.md)
- Python CLI `bootstrap-vllm` built with typer+rich
- Docker Compose orchestration (`docker/docker-compose.yml`)
- Entry: `src/bootstrap_vllm/cli.py` → commands/{up,down,status,logs,model}.py
- Config loader: `src/bootstrap_vllm/core/config.py` (pydantic-settings from `.env`)
- Commands: `up`, `down`, `status`, `logs`, `model switch/current/download/list`

### Current `.env` defaults (stale)
```bash
VLLM_MODEL=Qwen/Qwen2.5-72B-Instruct-AWQ   # pre-dates Qwen3 entirely
VLLM_PORT=8000
VLLM_MAX_MODEL_LEN=32768
VLLM_GPU_MEMORY_UTILIZATION=0.90
VLLM_ENFORCE_EAGER=true                    # GB10 sm_121 workaround (Jan 2026)
VLLM_IMAGE=nvcr.io/nvidia/vllm:25.12-py3
```

Recommended models in README are all AWQ/unquantized — no NVFP4 path exists in this harness yet.

---

## Proposed work for this session

**Goal:** Get `saricles/Qwen3-Coder-Next-NVFP4-GB10` serving through this harness with an OpenAI-compatible API on GB10.

### Step 1 — Audit current state (read-only)
Read the actual current files to see what's wired up today:
- `.env` and `.env.example`
- `docker/docker-compose.yml` — how env vars flow into the container, what args vLLM gets
- `src/bootstrap_vllm/core/config.py` — pydantic-settings schema
- `src/bootstrap_vllm/commands/up.py` — launch sequence
- `src/bootstrap_vllm/core/validate.py` — preflight checks

Verify the harness currently boots at all (`uv run bootstrap-vllm status`). `.venv/` and `dist/` are ~3 months old — may need `uv sync` refresh.

### Step 2 — Decide the image path

Two options, in preference order:

**Option A: Stay on NGC.** Check if `nvcr.io/nvidia/vllm:25.12-py3` (or a newer NGC tag like 26.02/26.03) ships vLLM ≥ 0.16.0-rc2 with Marlin NVFP4 backend. If yes, just set `VLLM_NVFP4_GEMM_BACKEND=marlin` and go.

**Option B: Switch to the community kernel image** `avarok/dgx-vllm-nvfp4-kernel:v23`. This is the confirmed-working stack from `saricles`'s benchmark. Downside: not NVIDIA-supported, pinned old tag.

**`[uncertain]`** NGC likely does ship a newer vLLM by April, but the specific Marlin NVFP4 backend readiness needs a quick check (look at NGC release notes or shell into a container and `pip show vllm`).

### Step 3 — Wire up NVFP4 model switching

Likely changes needed across the harness:
- New env var `VLLM_NVFP4_GEMM_BACKEND` (pass-through to container)
- Possibly new `VLLM_QUANTIZATION=nvfp4` hint or vLLM CLI arg
- Update `config.py` schema + docker-compose env pass-through
- Update `model` command's recommended list and/or validation
- Update `VLLM_MODEL` default to `saricles/Qwen3-Coder-Next-NVFP4-GB10`
- Revisit `VLLM_MAX_MODEL_LEN` — the benchmark used 1.3M KV cache room; 32768 is probably too low
- Revisit `VLLM_ENFORCE_EAGER` — may no longer be needed on newer vLLM+Blackwell

### Step 4 — Validate on actual hardware

- `uv run bootstrap-vllm up`
- `curl /v1/models` to confirm model loaded
- `curl /v1/chat/completions` smoke test
- Quick decode-rate measurement (aim for the ~60 tok/s ballpark to confirm Marlin NVFP4 is active, not falling back)

### Step 5 — Proxy integration (later)

The `/opt/dev/trt/proxy.py` FastAPI server exposes an OpenAI-compatible facade on port 8355 and forwards to the TRT-LLM backend. **Do not modify it this session.** Once vLLM here is proven, the user can decide whether to:
- Point `trt/proxy.py` at this vLLM endpoint (swap backend URL)
- Run both side-by-side for A/B
- Retire the TRT-LLM path entirely

---

## Hard-won context from the TRT-LLM side (don't re-learn)

- **GB10 = 128GB unified LPDDR5x, 273 GB/s bandwidth, SM120/121 Blackwell.** Budget <120GB total.
- `VLLM_ENFORCE_EAGER=true` was a Jan 2026 workaround for sm_121 CUDA graph failures. May not be needed on newer vLLM.
- NGC `nvcr.io/nvidia/vllm:25.12-py3` was selected because it shipped CUDA 13.0+ — that requirement still holds (SM121 needs CUDA 13).
- Models explicitly **ruled out** on GB10:
  - DeepSeek-V3/V3.2 (170GB+, multi-node)
  - Qwen3-Coder-480B even at FP4 (241GB)
  - Nemotron-3-Nano (Mamba hybrid KV cache issues)
  - Llama-3.2-90B (180GB FP8)
  - Qwen2.5-72B without aggressive quant
- **Alternative NVFP4 coder-capable model** worth remembering: `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` — native NVFP4, 60GB weights, 60.47% SWE-Bench Verified. General reasoner, not pure coder, but coding-capable. Fallback if Qwen3-Coder-Next has issues.

---

## Background reading (in `/opt/dev/trt/docs/kb/`)

The TRT-LLM project's KB has valuable cross-engine context:
- `vllm-vs-trtllm-gb10.md` — January engine comparison (now partly superseded by new NVFP4 evidence)
- `gb10-model-research-jan2026.md` — stack-ranked model list for GB10
- `coding-model-decision.md` — FP8-vs-NVFP4 trade-off writeup
- `blackwell-sm120-architecture.md`
- `quantization-fp8-nvfp4-guide.md`
- `qwen3-model-family-complete.md`

Don't read all of these upfront — only pull the ones relevant to the immediate step you're on.

---

## Sources (all verified 2026-04-12 via web search)

- https://huggingface.co/Qwen/Qwen3-Coder-Next
- https://huggingface.co/saricles/Qwen3-Coder-Next-NVFP4-GB10
- https://huggingface.co/RedHatAI/Qwen3-Coder-Next-NVFP4
- https://huggingface.co/GadflyII/Qwen3-Coder-Next-NVFP4/discussions/5
- https://huggingface.co/nvidia/Qwen3-Coder-480B-A35B-Instruct-NVFP4
- https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
- https://github.com/NVIDIA/TensorRT-LLM/issues/11932 (SM120 CUTLASS failure, OPEN)
- https://github.com/NVIDIA/TensorRT-LLM/issues/12230 (Qwen3-Next NVFP4 + DGX Spark, OPEN)
- https://github.com/NVIDIA/TensorRT-LLM/issues/12706 (TRITON MoE workaround, OPEN)
- https://github.com/NVIDIA/TensorRT-LLM/pull/12310, /12704, /12705, /11997 (SM121 fix PRs, all OPEN)
- https://forums.developer.nvidia.com/t/got-redhatai-qwen3-coder-next-nvfp4-running-on-dgx-spark-gb10/362773
- https://forums.developer.nvidia.com/t/issue-qwen3-next-80b-nvfp4-and-fp8-cannot-be-served-via-trtllm-serve-on-dgx-spark-gb10-trt-llm-1-3-0rc7/363540

---

## First move for the new session

1. Confirm you're in `/opt/dev/aeo/aeo-infra/vLLM` and read this file.
2. Ask the user: "Ready to start with Step 1 (read-only audit of the current harness), or do you want to reorder?"
3. Do NOT touch `/opt/dev/trt` — it's been set aside for now.
4. Do NOT re-research the NVFP4 landscape — the findings above are current as of 2026-04-12.
5. Use confidence markers (`[observed]`, `[inferred]`, `[uncertain]`, *`[researched]`*) when explaining causal claims per the user's global CLAUDE.md.
