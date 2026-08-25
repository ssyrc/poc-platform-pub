# poc-platform v6.34

## 변경 사항

- Dashboard PINNED DATA의 `실험 세팅 확인` / `결과 확인` 모달은 닫기 버튼만 표시하도록 정리했습니다.
- CUDA_VISIBLE_DEVICES 입력을 별도 `GPU 직접 지정` 구역이 아니라 일반 파라미터 필드와 같은 영역에서 보이도록 정리했습니다.
- Training MLPerf 세부 파라미터 UI를 single-node/multi-node 동작에 맞춰 재구성했습니다.
  - single-node + 1개 노드: host-local parallelism 구역 숨김.
  - single-node + 여러 노드: Host-local parallelism을 최상단에 표시하고 host별 NUM_GPUS/TP/PP/CP/CUDA_VISIBLE_DEVICES를 설정.
  - multi-node: GPUS_PER_NODE와 WORLD_SIZE만 직접 설정.
- Inference vLLM PD Disaggregation 세부 파라미터 UI를 instance 단위로 재구성했습니다.
  - Prefill/Decode instance별 hostname, NUM_GPUS, TP, CUDA_VISIBLE_DEVICES, gpu-memory-utilization, max-model-len, Port 설정.
  - Proxy Port 설정 추가. 기본 placement는 Prefill instance #1 host입니다.
  - Extra docker args를 추가해 `-v ...` 및 `-e ...` 형태의 docker run 옵션을 전달할 수 있게 했습니다.
- PD vLLM backend/script에 instance spec, proxy port, extra docker args 전달을 추가했습니다.
