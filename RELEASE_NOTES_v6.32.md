# poc-platform v6.32

- Training MLPerf bare metal에 Single-node / Multi-node 실행 모드 추가.
- Single-node 모드에서 host별 NUM_GPUS/TP 및 CUDA_VISIBLE_DEVICES 설정을 지원.
- Multi-node Training에서 torchrun nnodes/node_rank 기반 launcher 추가.
- Inference vLLM Single Instance에 Single-node / Multi-node 모드 선택 추가.
- PD Disaggregation에 prefill/decode num_instances 추가 및 GPU 분할 binding 추가.
- Training v4.1에서 V100을 A100과 동일 이미지 경로로 테스트 가능하게 허용.
- TQDM progress 로그 실시간 스트리밍 fallback 보강.
- Dashboard chart tooltip이 hover한 point의 row id를 우선 사용하도록 수정.
