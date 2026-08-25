# v6.46

- Fixed MLPerf Training v5.1 Hydra override for `trainer.log_every_n_steps`.
- v5.1 config does not define `trainer.log_every_n_steps` in some paths, so the launcher now uses `+trainer.log_every_n_steps=...` to append the key instead of overriding a missing key.
