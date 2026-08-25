# poc-platform v6.38

- Result/Run History 영역 높이를 동일하게 맞추고, 결과 확인의 대시보드 반영 버튼 높이를 Report 다운 버튼과 동일하게 고정했습니다.
- Training Precision UI를 정리했습니다. `trainer.precision` 표기를 `Precision`으로 바꾸고, FP8/FP8_Hybrid를 Precision 선택지로 통합했습니다.
- Dashboard의 Training axis/groups Test Args에 Precision과 Micro Batch Size를 추가했습니다.
- Dashboard pinned data 테이블에 그래프 표시 checkbox 필터를 추가해 선택된 pinned data만 그래프에 표시되도록 했습니다.
- Training v5.1에서 V100/A100 제한을 해제하고 기존 x86 Docker image 경로를 재사용하도록 했습니다.
