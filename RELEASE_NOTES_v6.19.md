# v6.19

- Training v4.1/v5.1 세부 파라미터 모달에 `MBS (Micro Batch Size)` 입력을 추가했습니다.
- `GBS (Global Batch Size)`와 같은 스타일로 MBS를 표시합니다.
- backend validation과 runner merge에서 MBS를 강제로 1로 덮어쓰지 않도록 수정했습니다.
- v4.1/v5.1 training scripts에서 `model.micro_batch_size=${MBS}`가 사용자 설정값을 반영하도록 유지하고, MBS=1 강제 제한을 제거했습니다.
- GBS 검증 공식은 `GBS % (MBS × DP) == 0` 기준으로 변경했습니다.
