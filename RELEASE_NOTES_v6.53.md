# v6.53

- Dashboard numeric X axis now uses nice min/max/tick intervals instead of raw data-only ticks.
- Inference vLLM Single Instance: GPU node count changes now update Tensor Parallel and CUDA_VISIBLE_DEVICES defaults together.
- Inference vLLM PD Disaggregation: Prefill/Decode node GPU count and instance count changes now update instance NUM_GPUS, TP, and CUDA_VISIBLE_DEVICES defaults together.
