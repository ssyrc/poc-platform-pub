# poc-platform v6.44

## Changes
- MLPerf Inference v6.0 now uses the fixed platform FP4 model directory: `${POC_PLATFORM_ROOT}/data/inference_llama2_70b/model_fp4`.
- Removed the UI input for FP4 model directory; users no longer need to provide it manually.
- MLPerf Inference v5.1 container execution now avoids UID 0 by running as the platform/data directory owner when the launcher is started as root.
- Applied the same non-root container-user selection to MLPerf Inference v6.0 for consistency.
