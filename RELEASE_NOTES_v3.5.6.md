# poc-platform v3.5.6

## Summary

This version renames the distributable folder/package from `mlperf-platform-*` to `poc-platform-*` and changes default paths to the new POC platform layout.

## Default layout

```text
${POC_PLATFORM_ROOT}/
├── files/                  # Python wheelhouse for air-gapped install
├── data/                   # benchmark data/model/docker image assets
└── poc-platform-v3.5.6/     # this web platform folder
```

## Changes

- Top-level folder is now `poc-platform-v3.5.6`.
- ZIP file is now `poc-platform-v3.5.6.zip`.
- `start_platform.sh` default venv path changed from an internal `mlperf-platform` folder to `.venv`.
- `WHEELHOUSE` now defaults to the new POC platform path: `${POC_PLATFORM_ROOT}/files`.
- `MLPERF_ROOT` now defaults to `${POC_PLATFORM_ROOT}`.
- `MLPERF_DATA_ROOT` now defaults to `${POC_PLATFORM_ROOT}/data`.
- Environment overrides are still supported: `POC_PLATFORM_ROOT`, `WHEELHOUSE`, `MLPERF_ROOT`, `MLPERF_DATA_ROOT`, `VENV`.
- Training/Inference behavior from v3.5.5 is preserved.
- CompileIQ remains a UI-only reserved option and is not passed to runtime scripts.

## Validation run before packaging

- `python3 -m py_compile backend/*.py`
- `bash -n start_platform.sh scripts/*.sh scripts/*/*.sh`
- `frontend/index.html` Babel transform
- Training dry-run
- Inference deploy-mode dry-run
