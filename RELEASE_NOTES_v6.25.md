# poc-platform v6.25

## 변경 사항

- Inference MLPerf v5.1 기본 Docker image를 새 MLPerf Inference v5.1 CUDA 12.9 / PyTorch 25.05 image로 변경했습니다.
  - 기본 x86_64: `${NVCR_PULL_PREFIX}/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64`
  - GH200: `${NVCR_PULL_PREFIX}/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-aarch64-Grace`
- Inference MLPerf v5.1/v6.0에서 Docker pull 실패 시 `${POC_PLATFORM_ROOT}/data/dockerimgs` 하위 tar 파일로 fallback `docker load`를 수행하도록 추가했습니다.
- `MLPERF_INFER_IMAGE_TAR` 환경변수로 inference image tar 경로를 override할 수 있게 했습니다.
