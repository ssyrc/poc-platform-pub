# poc-platform v6.18

## 변경 사항

- Training v4.1/v5.1 기본 `GBS`를 `128`로 변경했습니다.
- UI Training Hyperparameters 기본 `GBS`도 `128`로 변경했습니다.
- `GBS`가 명시되지 않은 Bare Metal 스크립트 실행에서도 기본값 `128`을 사용합니다.
- `GLOBAL_BATCH_SIZE`가 env로 들어오면 그 값을 우선 사용하고, 둘 다 없을 때만 `128`을 사용합니다.
- Training 로그에 `effective GBS = MBS * DP * grad_accum` 계산식을 출력합니다.

## 메모

Megatron/NeMo 기준 effective global batch size는 일반적으로 `micro batch size × data parallel size × gradient accumulation steps`입니다. 이 플랫폼은 `model.global_batch_size`와 병렬 설정을 넘기고, gradient accumulation은 NeMo/Megatron 내부 microbatch 계산에 맡깁니다.
