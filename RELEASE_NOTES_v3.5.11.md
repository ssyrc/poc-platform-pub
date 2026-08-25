# poc-platform v3.5.11

## 변경 사항

- Warewulf API Basic Auth 기본값을 backend/start script에 반영했습니다.
  - `WW_API_BASE=http://<management-endpoint>:8897`
  - `WW_BASIC_USER=admin`
  - `WW_BASIC_PASSWORD=<set in .env>`
- 브라우저 frontend에는 Warewulf 비밀번호를 노출하지 않습니다.
- Training 테스트 / Inference 테스트 UI를 구역별로 더 명확히 재배치했습니다.
  - Setting
  - Run History
  - 현재 실행
  - 모니터링
  - Result Analysis
- Add Node UI를 카드형으로 정리하고, Add Node / Run / Hyperparameters 버튼을 더 잘 보이도록 초록색 강조 버튼으로 변경했습니다.
- Hyperparameters 버튼이 카드 영역 밖으로 밀려 보이지 않도록 section header 안에 고정했습니다.

## 보류

- Warewulf node add/power API payload는 담당자 API 수정 이후 다음 버전에서 다시 연결합니다.
