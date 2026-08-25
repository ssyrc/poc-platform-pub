# poc-platform v6.0.6

## UI
- 실시간 모니터링 그래프가 잘리지 않도록 패널 높이와 차트 캔버스를 조정했습니다.
- 테스트 화면을 설정&실행, 실시간 모니터링, Log 확인, 결과 분석, Run History 5개 구역으로 재구성했습니다.
- Log 확인 구역에 live log, run.log path copy, report, 대시보드 반영 버튼을 배치했습니다.
- 테스트 메뉴 상태 표시를 텍스트 배지에서 컬러 dot으로 변경했습니다.
- GPU 노드 hostname 미입력 상태의 GPU probe 표시를 `0/0 free`로 변경했습니다.

## Results
- 결과 분석 Metrics 표에서 `_source`, `kind`, `global_batch_size`, status/path류 메타 필드를 제거했습니다.
- 성능 판단에 필요한 accuracy, loss, throughput, latency, TTFT/TPOT, duration 계열 metric만 우선 표시하도록 정리했습니다.
