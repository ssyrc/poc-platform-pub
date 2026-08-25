# poc-platform v6.13

## 변경 사항

- 테스트 탭 실시간 모니터링의 GPU UTIL / Power Draw timeline 이동 UI를 Recharts Brush에서 고정 폭 커스텀 슬라이더로 교체했습니다.
- 슬라이더는 그래프 아래에 회색 라인과 둥근 사각형 핸들만 표시하며, 구간 너비 resize traveller는 제거했습니다.
- Run History parsed metric 표시에서 hostname/node 계열 값이 metric chip으로 노출되지 않도록 blocklist를 보강했습니다.
