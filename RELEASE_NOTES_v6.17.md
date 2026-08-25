# poc-platform v6.17

## 변경 사항

- MLPerf Training v4.1/v5.1 기본 실행 override에 `trainer.log_every_n_steps=1`을 추가했습니다.
- stdout에서 step 진행 상황을 볼 수 있도록 `trainer.enable_progress_bar=true`를 기본값으로 추가했습니다.
- `PYTHONUNBUFFERED=1`, `TQDM_MININTERVAL=0`을 기본 적용해 로그 스트리밍 지연을 줄였습니다.
- 필요 시 `MLPERF_LOG_EVERY_N_STEPS`, `MLPERF_ENABLE_PROGRESS_BAR` 환경변수로 조정할 수 있습니다.

## 참고

- `max_epochs=1000`은 `max_steps`가 설정되어 있으면 주된 종료 조건이 아닙니다. 이번 증상은 step 제한 문제가 아니라 stdout step logging이 비활성화된 설정 때문입니다.
