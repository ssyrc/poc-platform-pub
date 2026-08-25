# poc-platform v6.29

## 변경 사항

- 실행 시작 시 backend에서 host별 GPU type을 자동 탐지합니다.
  - NVIDIA: `nvidia-smi --query-gpu=name` 기반
  - AMD: `rocm-smi --showproductname` 기반 best-effort 탐지
- frontend가 `H100`으로 잘못 보낸 경우에도 backend가 감지한 `A100`, `GH200`, `RTX_PRO_6000` 등으로 `node_gpu_map`과 run metadata를 보정합니다.
- 기존 history에 GPU sample의 `per_gpu.name`이 저장되어 있으면 Run History/Dashboard snapshot에서 GPU type을 fallback 복구합니다.
- `/api/hosts/{host}/gpu_type` endpoint를 추가해 host별 탐지 결과를 직접 확인할 수 있습니다.
