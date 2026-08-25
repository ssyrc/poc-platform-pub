# poc-platform v6.43

- Platform shutdown now terminates backend-owned active launcher subprocesses and persists active runs as `stopped`.
- Restored non-terminal runs are marked `stopped` because the backend cannot reattach launchers after restart/upgrade.
- Hardened vLLM Single Instance host/group generation so stale numeric host values cannot produce `--group 0`.
- MLPerf Inference v6.0 no longer fails during validation only because the FP4 quantized model directory is absent; it warns and lets the NVIDIA prebuild/build flow proceed. Added UI field for `MLPERF_QUANT_MODEL_DIR`.
