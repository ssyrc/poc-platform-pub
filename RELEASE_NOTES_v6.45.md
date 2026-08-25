# poc-platform v6.45

## Changes

- Inference MLPerf v5.1/v6.0 Docker execution hardening
  - Start MLPerf containers as root so NVIDIA container entrypoint/compat setup can initialize CUDA/GPU devices.
  - Switch to the selected non-root platform user inside the container before running MLPerf Makefile commands, avoiding `check_user_requirements` UID 0 failure.
  - Add `--privileged`, NVIDIA runtime detection, `NVIDIA_DRIVER_CAPABILITIES=all`, and supplemental host groups for Docker socket/NVIDIA device access.
- Cluster monitoring log persistence
  - Persist Warewulf/cluster monitoring logs in browser localStorage.
  - Persist last SSH status so disconnected → connected transitions are still logged after platform restart or version upgrade.
  - Increase retained cluster monitoring log entries from 160 to 500.
