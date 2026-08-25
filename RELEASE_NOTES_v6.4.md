# RELEASE NOTES v6.4

## 변경 사항

- 실행 history를 `.platform_state/runs.json`에 저장하여 backend 재시작 후에도 누적 표시되도록 수정했습니다.
- backend process가 재시작되면 frontend의 선택된 Run ID만 초기화하고, 저장된 history는 유지하도록 수정했습니다.
- Training / Inference vLLM 세부 파라미터의 `CUDA_VISIBLE_DEVICES` 입력에서 `4,5,6,7`처럼 콤마 포함 값을 정상 입력할 수 있도록 수정했습니다.
- UI 버전을 v6.4로 갱신했습니다.
