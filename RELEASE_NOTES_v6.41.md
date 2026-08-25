# v6.41

- MLPerf Training Precision UI에서 현재 NeMo/Megatron training path에서 실패하는 FP32/FP64 선택지를 제거했습니다.
- 과거 저장값이나 API 입력으로 FP32/FP64/32/64가 들어오면 실행 전에 bf16-mixed로 안전하게 정규화하도록 수정했습니다.
- 직접 스크립트 실행 시에도 unsupported full precision 값이 들어오면 컨테이너 내부에서 bf16-mixed로 보정하고 warning을 출력하도록 `mlperf_train_v41.sh`, `mlperf_train_v51.sh`를 보강했습니다.
- FP16/16/16-true legacy 입력은 기존처럼 FP16-mixed(`16-mixed`)로 정규화합니다.

## Docker registry/proxy update

- Updated bare-metal Docker bootstrap to use `${DOCKER_REGISTRY}` with the 3128 proxy and the current internal insecure registry list.
- Removed the old Docker service timeout override from the bootstrap path so the generated Docker config matches the current required two-file setup.
- Updated Docker Hub based image defaults to the `${DOCKER_HUB_PULL_PREFIX}/...` proxy path.
- On Docker pull failure, MLPerf and vLLM image preparation now rewrites Docker daemon/proxy config, restarts Docker, logs in to the internal registry, and retries the same pull before using fallback tar files.
