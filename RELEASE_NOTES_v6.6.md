# poc-platform v6.6

## 변경 사항

- Training 결과 parsing에서 마지막 `loss`/`train_loss` 값을 `train_loss`로 통일해 대시보드 Result metric에 반영.
- Training 세부 Hyperparameter에 `SAMPLES_COUNT`, `EVAL_SAMPLES` 입력 필드 추가.
- Dashboard Training axis/groups 선택지를 `Test Args`, `Parallelism`, `Result` optgroup으로 분리.
- Training Dashboard 선택지에서 중복 `global_batch_size` 제거, `Global batch size`는 입력 arg 기준 하나만 유지.
- Training Dashboard axis/groups에서 `model` 제거.
- 개별 Run report와 Dashboard report 모두 GPU Utilization / Power timeline table을 포함하도록 보강.
- `/api/runs/{run_id}/gpu_samples`는 해당 run에서 사용한 GPU만 필터링해 반환.
- Dashboard 최근 실행 상세의 GPU UT/Power 그래프 영역 폭 확대 및 parsed metric 영역 조정.

## 검증

- `python3 -m py_compile backend/*.py`
- `bash -n start_platform.sh scripts/*.sh scripts/*/*.sh`
- `frontend/app.jsx` Babel transform
- `frontend/index.html` inline Babel transform
- `zip -T poc-platform-v6.6.zip`
