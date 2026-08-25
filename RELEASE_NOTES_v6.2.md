# poc-platform v6.2

## 변경 사항

- Training Hyperparameters UI에서 `MAX_STEPS`를 필수 파라미터로 명확히 표시했습니다.
- Training/Inference 테스트 탭의 설정&실행 헤더 크기를 모니터링/로그 헤더와 동일한 체계로 맞췄습니다.
- 로그 확인 패널의 최대 높이를 실시간 모니터링 패널과 동일하게 제한하고, 로그 본문은 내부 스크롤로 확인하도록 정리했습니다.
- Run History 상세 영역을 `사용 노드/노드당 GPU 수량 → GPU UT/Power 그래프 → parsed metric → 대시보드 반영` 순서로 재배치했습니다.
- 실시간 GPU 모니터링과 Run History 그래프가 테스트에 할당된 GPU만 반영하도록 필터링했습니다.
- Dashboard 최근 실행 테이블을 RUN ID/KIND/STATUS/HOSTS/NUM_GPUS/STARTED/ENDED/Report/대시보드 반영 구조로 정리했습니다.
- Dashboard 최근 실행 상세에서 NIC 그래프를 제거하고 GPU UT/Power 그래프와 결과 요약만 표시하도록 변경했습니다.
- Bare Metal vLLM 실행 커맨드에서 중복으로 붙던 `--gpu-map` 인자를 제거했습니다.
- 사이드바 버전 표기를 v6.2로 갱신하고, 패키지 내 임시 백업/pycache 파일을 제거했습니다.
