# v6.63

- DockerHub 기반 이미지의 local/tag 기준을 `${DOCKER_HUB_IMAGE_PREFIX}/...`로 복구했습니다.
- `docker image inspect`, fallback tar `docker load`, `docker run`은 local tag를 사용합니다.
- `docker pull`만 `${DOCKER_HUB_PULL_PREFIX}/...` 경로로 시도하고, pull 성공 후 local tag로 `docker tag` 합니다.
- 적용 대상: MLPerf Training v4.1/v5.1, vLLM single image ensure, llm-d deploy image ensure, Training K8s default image tag.
