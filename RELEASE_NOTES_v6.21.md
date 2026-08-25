# poc-platform v6.21

## 변경 사항

- MLPerf Training v4.1 로그 파서를 carriage-return progress bar와 embedded `:::MLLOG`가 섞인 stdout에서도 안정적으로 동작하도록 보강했습니다.
- v4.1 progress 로그의 `reduced_train_loss`, `global_step`, `consumed_samples`와 MLLOG `train_loss`, `eval_accuracy`를 함께 parsing합니다.
- 공식 MLLOG `train_loss`가 있으면 이후 tqdm repaint의 rounded `reduced_train_loss`가 덮어쓰지 않도록 했습니다.
- Training Hyperparameters 세부 설정 UI에서 사용자 입력 대상이 아닌 `SAMPLES_COUNT`, `EVAL_SAMPLES` 필드를 제거했습니다.
- Dashboard Training Test Args에서도 `Samples count`, `Eval samples`를 제거하고, 결과 parsing metric으로만 유지합니다.
