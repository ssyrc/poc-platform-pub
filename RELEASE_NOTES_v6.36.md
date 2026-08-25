# poc-platform v6.36

## 변경 사항

- Bare-metal 테스트 실행 전 Docker가 없는 서버에 대해 오프라인 RPM 기반 Docker 설치, daemon/proxy/timeout 설정, 내부 registry 로그인 자동화 추가.
- Training v4.1/v5.1에서 `trainer.precision`을 UI에서 선택하고 `trainer.precision=...` Hydra override로 전달하도록 추가.
- Training multi-node 모드의 Hyperparameters UI에서 `NUM_GPUS` 대신 `GPUS_PER_NODE`만 노출되도록 정리.
- Run History 삭제 확인을 브라우저 native confirm 대신 자체 모달로 변경. 삭제 대상 run_id/status/duration/host 정보를 보여준 뒤 삭제.
- 테스트 결과 확인 영역의 `대시보드 반영` 버튼 높이를 `Report 다운` 버튼과 동일하게 조정.
