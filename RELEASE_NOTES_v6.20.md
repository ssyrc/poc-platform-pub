# v6.20

- Parse MLPerf Training v4.1 PyTorch Lightning/tqdm progress-bar metrics such as `reduced_train_loss`, `global_step`, and `consumed_samples`.
- Normalize `reduced_train_loss` to dashboard/result metric `train_loss`.
- Apply the same parser to completed `run.log` parsing and live-log fallback.
