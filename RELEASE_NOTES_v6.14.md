# poc-platform v6.14

## 변경 사항

- Dashboard 데이터 선택 영역을 `Training - MLPerf`, `Inference - MLPerf`, `Inference - vLLM` 단위의 카테고리 선택으로 재구성했습니다.
- 선택된 카테고리에 맞춰 version/model/환경/mode 선택 항목이 표시되도록 수정했습니다.
- Training - MLPerf 모델 선택지는 `llama2_70b_lora`, `llama31_8b`를 version과 독립적으로 표시합니다.
- Pinned Data가 카테고리, version, model, 환경, mode 선택값에 따라 함께 필터링되도록 보강했습니다.
- 실제 로드되는 `frontend/index.html` inline JSX와 `frontend/app.jsx`를 동기화했습니다.
