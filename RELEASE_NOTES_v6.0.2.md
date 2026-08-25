# poc-platform v6.0.2

## 변경 사항

- 클러스터 관리 탭에 전원 관리/SSH 연결 상태 로그 패널을 추가했습니다.
- Warewulf 노드 상세 정보 모달의 카드/표 스타일을 개선했습니다.
- 전원 관리 테이블 열 너비를 조정해 요청 버튼이 한 줄로 보이도록 수정했습니다.
- 결과 분석 패널에 log path 표시와 copy 버튼을 항상 노출하도록 수정했습니다.
- Training MLPerf Bare Metal 실행 시 GPU 노드 설정의 전체 GPU 수에 맞춰 NUM_GPUS, MLPERF_NUM_GPUS, TP 기본값을 자동 동기화합니다.
- Inference MLPerf v6.0의 TP size 기본값을 GPU 노드 설정의 전체 GPU 수 기준으로 자동 설정합니다.
- Inference vLLM PD Disaggregation의 Prefill/Decode TP 기본값을 각 역할 노드의 최대 GPU 수 기준으로 자동 설정합니다.
- vLLM Bare Metal serve port 기본값을 9001로 통일했습니다.
- 실시간 모니터링, 결과 분석, Run History 패널 높이를 더 compact하게 제한하고 내부 스크롤 처리했습니다.

## 정적 검증

- python -m py_compile backend/*.py
- bash -n scripts/*.sh scripts/*/*.sh
- frontend/app.jsx Babel transform
- frontend/index.html embedded JSX Babel transform
- zip integrity test
