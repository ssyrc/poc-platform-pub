# poc-platform v6.10

- 테스트 탭 실시간 모니터링 그래프가 탭 이동 후에도 해당 실험 시작 시점부터의 GPU/Power 샘플을 다시 불러오도록 수정했습니다.
- GPU 노드 설정의 hostname/GPU 입력칸과 노드 추가 버튼을 항상 붙여 배치하고, Hyperparameters 버튼과 하단 높이를 맞췄습니다.
- FAILED/ERROR/PARTIAL Run은 Run History와 Dashboard 최근 실행 상세에서 노드/metric 대신 error message를 우선 표시합니다.
- FAILED Run에서도 수집된 GPU UTIL/Power draw 그래프는 계속 표시되도록 유지했습니다.
