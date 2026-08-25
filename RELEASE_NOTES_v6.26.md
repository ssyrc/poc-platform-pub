# poc-platform v6.26

## 변경 사항

- MLPerf Inference v6.0에서 `GPU_TYPE=GH200`일 때 aarch64 Grace용 image/tag를 기본 사용하도록 추가했습니다.
- MLPerf Inference v6.0 GH200 docker load fallback tar를 `data/dockerimgs/mlperf-inference_tensorrt_llm_release-feat-1.2-mlpinf-b5ddff4_mlperf-main-f538816_jan28_aarch64.tar`로 추가했습니다.
- vLLM GH200 기본 image를 `rajesh550/gh200-vllm:0.11.1rc2`로 변경했습니다.
- vLLM GH200 docker load fallback tar를 `data/dockerimgs/gh200-vllm_0.11.1rc2.tar`로 변경했습니다.
