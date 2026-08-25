# poc-platform v6.8

- Inference MLPerf 세부 파라미터에 Bare Metal CUDA_VISIBLE_DEVICES 직접 지정 필드를 추가했습니다.
- MLPerf Inference 기본 base model path를 platform data layout(`${POC_PLATFORM_ROOT}/data/inference_llama2_70b/model`) 기준으로 보정했습니다.
- Training/Inference 설정 상단의 종류 선택 영역을 명확히 표시하고 localStorage key를 v6.8로 분리했습니다.
- MLPerf inference model/data override env(`MLPERF_BASE_MODEL_DIR`, `MLPERF_PREPROCESSED_DIR`, `MLPERF_ENGINE_DIR`, `MLPERF_QUANT_MODEL_DIR`) 전달을 지원합니다.
