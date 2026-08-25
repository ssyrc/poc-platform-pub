# poc-platform v6.24

## 변경 사항

- vLLM Bare Metal 실행에서 `${DOCKER_HUB_IMAGE_PREFIX}/vllm/vllm-openai:latest` 이미지가 없을 때 `${POC_PLATFORM_ROOT}/data/dockerimgs/vllm-openai_latest.tar`에서 `docker load` 하도록 추가했습니다.
- PD Disaggregation vLLM 실행에서 `vllm-openai-nixl:v0.14.0` 이미지가 없을 때 `${POC_PLATFORM_ROOT}/data/dockerimgs/vllm-openai-nixl_v0.14.0.tar`에서 `docker load` 하도록 추가했습니다.
- llm-d deploy mode에서 `${DOCKER_HUB_IMAGE_PREFIX}/vllm/vllm-openai:latest` 이미지 fallback tar 경로를 `${POC_PLATFORM_ROOT}/data/dockerimgs/vllm-openai_latest.tar`로 추가했습니다. Kubernetes 런타임을 고려해 `docker load`와 `ctr -n k8s.io images import`를 모두 시도합니다.
- llm-d deploy pod의 `imagePullPolicy`를 `IfNotPresent`로 지정했습니다.
- zip 내부 최상위 폴더를 `poc-platform-v6.24/`로 맞췄습니다.
