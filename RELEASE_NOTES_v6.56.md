# v6.56

- Fix MLPerf Inference v5.1 `/data` permission failure by bind-mounting platform data root to `/data` inside the container.
- Export `DATA_DIR=/data` and `MLPERF_DATA_DIR=/data` for MLPerf Makefile compatibility.
- Apply the same `/data` bind mount safeguard to MLPerf Inference v6.0.
