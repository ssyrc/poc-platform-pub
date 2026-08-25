# v6.39

- Training 테스트 UI에서 `NUM_GPUS` 노출을 제거하고, GPU 수량 표시는 `GPUS_PER_NODE`로 통일했습니다.
- bare-metal single-node 모드에서 여러 host를 추가한 경우, host별 `GPUS_PER_NODE`만 노출되도록 정리했습니다.
- 로그 확인 구역의 host 필터와 LOG PATH 표시를 연결해, host 선택 시 해당 host의 `run.log` 경로가 표시되도록 수정했습니다.
- bare-metal single-node fan-out 실행에서 한 host의 fatal error가 다른 host launcher를 자동 종료하지 않도록 backend fatal 처리 로직을 분리했습니다.
- Training Precision 매핑을 NeMo 실행 오류 기준으로 수정했습니다. `FP16`은 `trainer.precision=16`, `BF16`은 `trainer.precision=bf16`으로 전달됩니다.
