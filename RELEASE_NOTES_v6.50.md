# v6.50

- Dashboard chart grouping now automatically expands the active series key when version/model/environment filters are set to `all`.
  - Example: selected groups `gpu_type` + all filters => `gpu_type / version / model / env` series labels.
  - This prevents unrelated runs from being connected into the same line.
- Inference MLPerf v5.1/v6.0 now emits `[INFO] log_dir=...` immediately after `run.log` is opened, so the Log Path field appears while the run is still running.
