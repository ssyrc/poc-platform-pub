# poc-platform v6.15

## 변경 사항

- Dashboard 데이터 선택 UI를 기존 카테고리 하이라이트 방식으로 복원했습니다.
- Dashboard 필터를 Training/Inference 카테고리 아래에서 테스트 종류, version, model, 환경, mode 순서로 동작하도록 정리했습니다.
- 필터 옵션과 Pinned Data 제목에서 데이터 개수 표시를 제거했습니다.
- 기존 pinned/history 데이터에서 env가 비어 있는 경우 Bare Metal로 fallback 처리합니다.
- 앞으로 Dashboard pin 저장 시 suite, test_kind, version, model, env, mode metadata를 명시 저장합니다.
- legacy MLPerf Inference pin이 kind=mlperf로 저장된 경우 model 기반으로 Inference로 복구합니다.
