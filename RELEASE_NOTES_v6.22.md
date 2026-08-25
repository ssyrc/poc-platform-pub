# v6.22

- Fixed live log streaming for MLPerf Training v4.1 progress-bar output.
- Subprocess stdout is now chunk-read and split on both newline and carriage return so tqdm/NeMo progress updates appear in the web UI while the run is still active.
- Cleaned ANSI terminal escape sequences from stored UI log lines.
- Documented current A100 support status: Training v4.1 script allows A100; Training v5.1 script does not allow A100.
