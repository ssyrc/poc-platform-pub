# v6.47

- Fixed MLPerf Training v5.1 Hydra override for `trainer.enable_progress_bar` by appending it as `+trainer.enable_progress_bar=...` because the v5.1 NeMo/Hydra config may not define that key in struct mode.
- Rechecked v5.1 trainer overrides after the previous `log_every_n_steps` issue. `trainer.devices`, `trainer.num_nodes`, `trainer.max_steps`, `trainer.limit_val_batches`, `trainer.val_check_interval`, and `trainer.precision` had already passed Hydra composition before the failure point, so the risky missing keys are now handled as append-only: `log_every_n_steps` and `enable_progress_bar`.
