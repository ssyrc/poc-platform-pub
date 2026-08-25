# poc-platform v6.23

- Dashboard Pinned Data에서 log path 실제 경로를 숨기고 copy 버튼만 표시.
- Dashboard Pinned Data에 Hyperparameter 확인 열 추가.
- 대시보드 반영 시 실행 당시 세부 hyperparameter snapshot을 저장.
- 기존 pin은 저장된 dims/metrics 기준 fallback으로 확인 가능.
- Dashboard Training - MLPerf 모델 선택지를 테스트 탭과 동일하게 version별로 제한.
  - v4.1: llama2_70b_lora
  - v5.1: llama2_70b_lora, llama31_8b
