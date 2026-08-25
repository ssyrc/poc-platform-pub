# poc-platform v6.48

## Fixes

- Training MLPerf v5.1 Hydra overrides are now generated with `++` for platform-injected `trainer.*`, `model.*`, `exp_manager.*`, `ckpt_root`, and `data_root` values.
- This avoids repeated struct-config failures such as:
  - `Could not override 'trainer.log_every_n_steps'`
  - `Could not override 'trainer.enable_progress_bar'`
  - `Could not override 'trainer.precision'`
  - likely follow-up failures on model-level platform overrides.
- Extra Hydra overrides entered through `MLPERF_EXTRA_OVERRIDES` are normalized safely: plain `trainer.*=`, `model.*=`, `exp_manager.*=`, `ckpt_root=`, and `data_root=` entries are promoted to `++...`, while user-specified `+...`, `++...`, and `~...` entries are preserved.
