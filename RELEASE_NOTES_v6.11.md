# poc-platform v6.11

## 변경 사항

- 테스트 탭 설정&실행 구역에서 `종류 선택` 필드를 제거했습니다.
- Dashboard 필터를 `category → 테스트 종류 → version/model/환경/mode` 구조로 재정렬했습니다.
  - Training: category → MLPerf → version → model → 환경 선택
  - Inference MLPerf: category → MLPerf → version → model → 환경 선택
  - Inference vLLM: category → vLLM → model → 환경 선택 → mode
- Pinned Data와 Dashboard chart data가 선택된 필터 기준으로만 표시되도록 수정했습니다.
- Run에서 대시보드 반영 시 version/env/mode metadata를 함께 저장하도록 보강했습니다.
- GPU Utilization/Power Draw chart Brush를 얇은 회색 track과 둥근 회색 handle 스타일로 변경했습니다.
- 실시간 모니터링 패널에서 Brush가 스크롤 없이 보이도록 chart/panel overflow와 높이를 조정했습니다.
- 테스트 탭 Run 버튼에 보라색 그라데이션 스타일을 적용했습니다.
