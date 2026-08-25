# poc-platform v6.67

POC용 Training/Inference 테스트 웹 플랫폼입니다. FastAPI backend와 React SPA frontend, 그리고 Training/Inference 실행 스크립트를 하나의 패키지로 제공합니다.

## 실행

```bash
git clone https://github.com/ssyrc/poc-platform.git
cd poc-platform
chmod +x start_platform.sh scripts/*.sh scripts/*/*.sh
./start_platform.sh
```

기본 접속 주소:

```text
http://<서버IP>:8089
```


## 환경 설정

사내 endpoint, registry credential, 개인 경로 등 site-specific 값은 Git에 올리지 않습니다.

```bash
cp .env.example .env
vi .env
```

`.env`는 `start_platform.sh`와 `scripts/common.sh`에서 자동으로 로드되며 `.gitignore`에 포함되어 있습니다.

## 주요 구성

```text
backend/
  app.py          FastAPI API, run/result/report endpoint
  runner.py       run kind별 실행 dispatcher
  parser.py       실행 결과 및 로그 파싱
  state.py        run/log/GPU sample in-memory state
  gpu_monitor.py  nvidia-smi/RDMA counter 기반 실시간 모니터링
  cluster.py      Warewulf/Kubernetes 관리 API
  topology.py     GPU↔NIC topology 조회

frontend/
  index.html      실제 브라우저에서 로드되는 React SPA
  app.jsx         index.html inline JSX와 동일한 원본
  vendor/         air-gapped 환경용 frontend dependency

scripts/
  training/train_k8s.sh
  llmd/llmd_run.sh, llmd/llmd_serve.sh
  vllm/vllm_run.sh, vllm/vllm_bench.sh
  pd/pd_run.sh
  mlperf_*.sh
```

## v6.39 변경 요약

- Training UI의 GPU 수량 표기를 GPUS_PER_NODE로 통일했습니다.
- 로그 확인 host 필터 선택 시 LOG PATH도 host별로 변경됩니다.
- single-node fan-out 실행에서 한 host 실패가 다른 host를 stopped 처리하지 않도록 수정했습니다.
- FP16/BF16 Precision 매핑을 NeMo가 파싱 가능한 값으로 수정했습니다.

## v6.37 변경 요약

- Training multi-node 세부 파라미터 창에서 hostname별 `CUDA_VISIBLE_DEVICES` 지정값이 실제 실행 파라미터로 전달되도록 수정했습니다.
- Training precision UI를 `FP64`, `FP32`, `FP16`, `BF16`, `BF16-mixed`, `FP16-mixed` 6개 항목으로 제한하고, 내부 값은 Lightning/NeMo 허용값으로 변환합니다.
- `fp16-mixed` 입력은 유효하지 않으므로 내부적으로 `16-mixed`로 정규화합니다.
- Training multi-node UI에서 `NUM_GPUS` 노출을 제거하고 `GPUS_PER_NODE`만 사용하도록 정리했습니다.
- Inference vLLM single-instance의 vLLM serve 전용 args를 GuideLLM이 아니라 vLLM Serve 구역에서 지정하도록 이동했습니다.
- Inference vLLM PD Disaggregation의 Prefill/Decode Common 구역에 `gpu-memory-utilization`, `max-model-len`, `Extra args`, `Extra docker args`를 분리했습니다.
- Dashboard 최근 실행 삭제 버튼도 테스트 탭 Run History와 동일한 삭제 확인 모달을 띄우도록 수정했습니다.
- 테스트 결과 확인 구역의 `대시보드 반영` 버튼 높이와 결과/Run History 패널 높이를 정리했습니다.

## 검증 커맨드

```bash
python3 -m py_compile backend/*.py
bash -n start_platform.sh scripts/*.sh scripts/*/*.sh
# frontend/app.jsx 및 frontend/index.html inline Babel transform 확인
```


## v6.18 이전 변경 요약
- 테스트 결과 확인 버튼 폭을 조정해 `Report 다운 ▼` 버튼이 짜부되지 않도록 수정했습니다.
- 실시간 GPU Utilization/Power Draw 차트에 x축 Brush를 추가해 과거 구간을 탐색할 수 있게 했습니다.
- Report HTML의 GPU monitoring을 평균 summary가 아니라 사용 GPU 기준 10초 간격 timeline table로 변경했습니다.
- Dashboard 최근 실행 상세를 GPU UT 그래프, Power 그래프, parsed metric, 대시보드 반영 버튼이 한 줄에 보이도록 재배치했습니다.


