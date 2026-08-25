# poc-platform v6.37 Release Notes

## 변경 사항

- Training multi-node 세부 파라미터 창에서 hostname별 `CUDA_VISIBLE_DEVICES`를 지정하고 실제 실행 파라미터로 전달하도록 수정했습니다.
- Training precision UI를 `FP64`, `FP32`, `FP16`, `BF16`, `BF16-mixed`, `FP16-mixed`로 제한했습니다.
- UI precision 값은 Lightning/NeMo 허용값으로 변환합니다.
  - `FP64` → `64`
  - `FP32` → `32`
  - `FP16` → `16-true`
  - `BF16` → `bf16-true`
  - `BF16-mixed` → `bf16-mixed`
  - `FP16-mixed` → `16-mixed`
- legacy/오입력값 `fp16-mixed`는 `16-mixed`로 정규화합니다.
- Training multi-node Hyperparameters와 세부 파라미터 UI에서 `NUM_GPUS`를 제거하고 `GPUS_PER_NODE`만 사용하도록 정리했습니다.
- vLLM single-instance에서 vLLM serve 전용 `Extra args`, `Extra docker args`, `gpu-memory-utilization`, `max-model-len`을 vLLM Serve 구역으로 이동했습니다.
- vLLM PD Disaggregation에서 Prefill Common / Decode Common 구역을 추가하고 공통 serve args를 각 role별로 지정할 수 있게 했습니다.
- Dashboard 최근 실행 삭제 버튼이 테스트 Run History와 동일한 삭제 확인 모달을 띄우도록 수정했습니다.
- 결과 확인 구역의 `대시보드 반영` 버튼 높이와 결과/Run History 패널 높이를 정리했습니다.

## 검증

```bash
python -m py_compile backend/*.py
bash -n start_platform.sh
bash -n scripts/*.sh scripts/*/*.sh
# frontend/app.jsx Babel transform
# frontend/index.html inline Babel transform
zip -T poc-platform-v6.37.zip
```
