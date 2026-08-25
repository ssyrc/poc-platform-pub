# v6.61

- Dashboard Pinned Data 중복 반영 문제 수정.
  - 기존 random pin id 대신 `run_id + host` 기반 stable id 사용.
  - localStorage와 backend dashboard state를 merge할 때 같은 run/host는 하나로 dedupe.
  - 기존에 이미 중복 저장된 dashboard.json/localStorage 데이터도 새 버전 로딩 시 자동 정리.
- Dashboard 반영 버튼/전체 반영 버튼에서 stale pinned state를 append하지 않고 semantic merge 하도록 수정.
- Backend `/api/dashboard` 저장/복원 로직도 동일한 semantic dedupe 기준으로 보강.
