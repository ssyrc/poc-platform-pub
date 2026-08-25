# poc-platform v6.0.1

## UI changes
- GPU node list in Training / Inference test cards now shows up to 3 nodes and scrolls within the card after that.
- Inference MLPerf scenario is fixed to Offline and removed from the hyperparameter UI.
- Inference vLLM hyperparameters were reorganized by runtime:
  - Bare Metal / Single Instance: vLLM Serve + GuideLLM sections.
  - Bare Metal / PD Disaggregation: vLLM Serve Prefill/Decode + GuideLLM sections.
  - K8s: llm-d + GuideLLM sections.
- Tensor parallel defaults to the configured GPU count when not explicitly set.
- vLLM serve port defaults to 9001.
- served-model-name is derived from the last segment of model_path and is no longer shown in the UI.
- Live Monitoring, Result Analysis, and Run History panels use compact fixed-height scrolling.
- Result Analysis status moved from the metrics body to the title row as a compact status badge.

## Runtime behavior
- Bare Metal vLLM keeps using the existing vLLM benchmark script path.
- K8s vLLM keeps using the existing llm-d + GuideLLM script path.
- Inference MLPerf still passes `MLPERF_INFER_SCENARIO=Offline` internally.
