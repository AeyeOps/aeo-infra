# vLLM Deployment Plan for NVIDIA GB10

## Executive Summary

This document outlines the deployment strategy for vLLM on NVIDIA GB10 (Grace Blackwell) hardware. The solution provides a Python CLI (`bootstrap-vllm`) that handles both provisioning and teardown, serving models via an OpenAI-compatible API.

**Implementation**: Python CLI using typer+rich, with Docker Compose for container orchestration.

### Why Docker Over Native

| Factor | Docker | Native Source Build |
|--------|--------|---------------------|
| **CUDA 13.0+ compatibility** | Handled by container | Manual toolchain setup |
| **ARM64+GPU support** | Pre-validated NGC images | Complex cross-compilation |
| **Reproducibility** | Guaranteed via image tags | Depends on system state |
| **Idempotency** | Container lifecycle is atomic | Requires careful state mgmt |
| **Upgrade path** | Pull new image tag | Full rebuild required |

The GB10's sm_121 compute capability requires CUDA 13.0+, which is only available in recent NGC containers or requires manual toolchain installation. Docker eliminates this complexity while preserving full GPU performance through NVIDIA Container Toolkit.

---

## Directory Structure

```
vLLM/
├── pyproject.toml              # Package config, dependencies, tool settings
├── Makefile                    # 3 targets: clean, validate, build
├── .env.example                # Configuration template
├── .env                        # Local config (gitignored)
├── docker/
│   └── docker-compose.yml      # Uses ${VAR} interpolation from .env
├── models/                     # Model cache (gitignored contents)
│   └── .gitkeep
├── scripts/
│   ├── make_clean.py           # Makefile delegate: clean
│   ├── make_validate.py        # Makefile delegate: ruff + ty
│   └── make_build.py           # Makefile delegate: PyInstaller build
└── src/
    └── bootstrap_vllm/
        ├── __init__.py         # Version from importlib.metadata
        ├── __main__.py         # Entry: from .cli import app; app()
        ├── cli.py              # Main typer app, command registration
        ├── commands/           # CLI subcommands
        │   ├── up.py           # Start vLLM container
        │   ├── down.py         # Stop and remove
        │   ├── status.py       # Health check display
        │   ├── logs.py         # Stream container logs
        │   └── model.py        # Model download/list subcommands
        ├── core/               # Core functionality
        │   ├── config.py       # pydantic-settings, .env loading
        │   ├── docker.py       # Docker/compose operations
        │   └── validate.py     # GPU, Docker, health checks
        └── utils/              # Utilities
            ├── output.py       # Rich console helpers
            └── process.py      # Subprocess execution
```

---

## CLI Usage

```
bootstrap-vllm [OPTIONS] COMMAND

Commands:
  up       Start vLLM server
  down     Stop and remove containers
  status   Show service health
  logs     Stream container logs
  model    Model management (download, list)

Global Options:
  --version, -V    Show version
  --help           Show help

Up Command Options:
  --force, -f      Force recreation even if running
  --model MODEL    Override model from config (future)
  --port PORT      Override port from config (future)
```

### Idempotency

- `up`: Creates if missing, no-op if running (unless `--force`)
- `down`: Stops if running, no-op if already stopped
- Configuration in `.env` is never deleted by `down`

---

## Configuration

Single source of truth in `.env`:

```bash
# Model Configuration
VLLM_MODEL=Qwen/Qwen2.5-72B-Instruct-AWQ
VLLM_QUANTIZATION=awq

# Server Configuration
VLLM_HOST=0.0.0.0
VLLM_PORT=8000
VLLM_MAX_MODEL_LEN=32768

# GPU Configuration
VLLM_GPU_MEMORY_UTILIZATION=0.90
VLLM_TENSOR_PARALLEL_SIZE=1
VLLM_ENFORCE_EAGER=true

# Paths
VLLM_MODEL_CACHE=./models
HF_TOKEN=                    # Optional: for gated models

# Docker
VLLM_IMAGE=nvcr.io/nvidia/vllm:25.12-py3
```

The `docker-compose.yml` uses `${VAR}` interpolation to read these values directly.

---

## Health Check and Validation

### Startup Validation

The CLI validates prerequisites before starting:

1. Docker daemon running
2. GPU available via nvidia-smi
3. Configuration file exists

### Runtime Monitoring

| Endpoint | Purpose | Expected Response |
|----------|---------|-------------------|
| `/health` | Liveness probe | HTTP 200 |
| `/v1/models` | Model availability | JSON with model list |
| `/metrics` | Prometheus metrics | Prometheus format |

---

## Known Limitations and Workarounds

### GB10/Blackwell-Specific Issues

| Issue | Impact | Workaround |
|-------|--------|------------|
| sm_121 graph capture failures | CUDA graphs may fail | Use `--enforce-eager` flag |
| Flash Attention 3 optional | FA3 not in all builds | Falls back to FA2 or eager |
| CUDA 13.0 requirement | Older containers fail | Use NGC 25.01+ images |
| Unified memory semantics | Different from discrete | Set `gpu-memory-utilization=0.9` |

### Container Image Selection

| Image | Status | Notes |
|-------|--------|-------|
| `nvcr.io/nvidia/vllm:25.12-py3` | Recommended | Official NVIDIA, CUDA 13.0+ |
| `drikster80/vllm-aarch64-openai` | Alternative | Community ARM64 build |
| `vllm/vllm-openai:latest` | Not recommended | x86_64 only |

### Memory Management

The GB10's unified memory architecture means GPU and CPU share the same 128GB pool:

- Set `VLLM_GPU_MEMORY_UTILIZATION=0.90` (default)
- Leave 10-15GB for system and CPU-side operations
- Monitor with `nvidia-smi dmon -s um` for unified memory stats

---

## Model Recommendations for 128GB Unified Memory

| Model | Size | Quantization | Est. Memory | Use Case |
|-------|------|--------------|-------------|----------|
| Qwen2.5-72B-Instruct-AWQ | 38GB | AWQ 4-bit | ~45GB | General purpose (recommended) |
| Llama-3.1-70B-Instruct-AWQ | 37GB | AWQ 4-bit | ~44GB | Alternative general purpose |
| DeepSeek-Coder-V2-Lite | 16GB | None | ~20GB | Code-focused |
| Qwen2.5-32B-Instruct | 64GB | None | ~70GB | Higher quality, no quant |

**Note**: AWQ quantization with Marlin kernels provides ~1.5x inference speedup on Blackwell architecture.

---

## Security Considerations

- Model cache directory should have appropriate permissions (700)
- HuggingFace token (if used) stored only in `.env` files (gitignored)
- Container runs as non-root user inside
- API exposed only on localhost by default; use reverse proxy for external access

---

## Future Enhancements

1. **Multi-model serving**: Load multiple models with model routing
2. **Prometheus/Grafana integration**: Pre-built dashboards
3. **Systemd service**: Auto-start on boot
4. **Runtime config overrides**: `--model` and `--port` flags write to temp env
