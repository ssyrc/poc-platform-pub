# poc-platform v6.35

## 변경 요약

- Dashboard / Test Run History에 기록 삭제 기능을 추가했습니다. 삭제 시 백엔드 메모리와 저장된 run history에서 제거되어 다른 탭에서도 보이지 않습니다.
- Dashboard Pinned Data의 `실험 세팅 확인`, `결과 확인` 모달에서 취소/적용 버튼을 제거했습니다.
- Test Run History를 오른쪽 상세 패널 없는 단순 카드형 목록으로 정리하고, duration/status/대시보드 반영 상태를 표시하도록 변경했습니다.
- 대시보드 반영 버튼에 `대시보드 반영 중`, `대시보드 반영 완료되었습니다` 상태 문구를 추가했습니다.
- History 선택 시 로그가 비어 보이는 문제를 줄이기 위해 기존 로그를 HTTP로 먼저 복원한 뒤 SSE 스트림을 연결하도록 변경했습니다.
- CUDA_VISIBLE_DEVICES 입력 UI의 hostname/설명 문구를 제거하고 필드명을 단순화했습니다.
- Training 세부 파라미터 UI에서 `HOST-LOCAL PARALLELISM` 표기를 `노드별 파라미터 지정`으로 변경했습니다.
- Training multi-node 세부 파라미터 UI에서 `MLPERF_NUM_GPUS`, `FP8_HYBRID` 노출을 제거하고 노드별 CUDA_VISIBLE_DEVICES 지정을 추가했습니다.
- Inference vLLM single instance에서 CUDA_VISIBLE_DEVICES를 vLLM Serve 구역 안에서 지정하도록 배치했습니다.
- Inference vLLM PD Disaggregation 세부 파라미터 UI에서 prefill/decode serve 구역과 하단 vLLM Serve 구역을 제거하고, instance 수 + instance별 파라미터 + Proxy + GuideLLM 순서로 정리했습니다.
