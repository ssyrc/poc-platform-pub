# poc-platform

POC용 Training/Inference 테스트 웹 플랫폼입니다. FastAPI backend와 React SPA frontend, 그리고 Training/Inference 실행 스크립트를 하나의 패키지로 제공합니다.

## 실행

```bash
unzip poc-platform.zip
cd poc-platform
chmod +x start_platform.sh scripts/*.sh scripts/*/*.sh
./start_platform.sh
```

기본 접속 주소:

```text
http://{서버ip}:8100
```

## 운영 배포 (systemd)

`poc-platform-latest`(포트 8100, `http://{서버ip}:8100`)는 터미널 종료/재부팅에도 유지되도록
systemd 서비스로 등록되어 있습니다. 서비스 파일: `/etc/systemd/system/poc-platform.service`

```ini
[Unit]
Description=POC GPU Benchmark Platform (uvicorn)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/poc-platform/poc-platform-latest
Environment="PATH=/apps/python/Python-3.13.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PORT=8100"
Environment="MLPERF_RELOAD=0"
Environment="SKIP_PIP_INSTALL=0"
Environment="MLPERF_PYTHON=/apps/python/Python-3.13.0/bin/python3"
Environment="MLPERF_ENV_MODULE=python-3.13.0"
ExecStart=/usr/bin/env bash /opt/poc-platform/poc-platform-latest/start_platform.sh
Restart=on-failure
RestartSec=10
StandardOutput=append:/opt/poc-platform/poc-platform-latest/.poc_platform.log
StandardError=append:/opt/poc-platform/poc-platform-latest/.poc_platform.log
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

운영 명령:

```bash
systemctl status poc-platform.service
systemctl restart poc-platform.service   # poc-platform-latest/ 코드 갱신 후 재기동
journalctl -u poc-platform.service -f    # 또는 tail -f .poc_platform.log
```

`start_platform.sh`는 기동 시 `module load python-3.13.0`을 자동으로 실행합니다(이 host의
`/apps/python/Python-3.13.0` 툴체인이 이 module 환경 없이 venv/pip를 만들면 `bin/activate`가
누락된 채로 조용히 깨진 venv가 만들어지는 문제가 있었음, `MLPERF_ENV_MODULE` 환경변수로 다른
module명 지정 또는 빈 문자열로 끄기 가능). systemd(`ExecStart=env bash ...`)는 로그인/인터랙티브
셸이 아니라 `~/.bashrc`나 `/etc/profile.d/modules.sh`를 자동으로 읽지 않으므로, 스크립트 안에서
modules init을 직접 source합니다.

`poc-platform-dev` 디버그 인스턴스(예: 8101)는 기본적으로 systemd 등록 없이 터미널에서
`PORT=8101 ./start_platform.sh`로 수동 기동합니다.

## DEV/디버그 배포 (systemd)

터미널을 꺼도 dev 인스턴스가 유지되어야 할 때는 아래처럼 별도 서비스로 등록할 수 있습니다.
`WorkingDirectory`는 dev용 배포 폴더 `poc-platform-dev`를 사용합니다(과거에는 `poc-platform-vX.Y.Z`
버전 폴더명을 그대로 썼으나, 폐쇄망 서버에서 `poc-platform-dev`로 폴더명을 고정했습니다).
`/etc/systemd/system/poc-platform-dev.service`:

```ini
[Unit]
Description=POC GPU Benchmark Platform (dev/debug, uvicorn)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/poc-platform/poc-platform-dev
Environment="PATH=/apps/python/Python-3.13.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PORT=8101"
Environment="MLPERF_RELOAD=0"
Environment="SKIP_PIP_INSTALL=0"
Environment="MLPERF_PYTHON=/apps/python/Python-3.13.0/bin/python3"
Environment="MLPERF_ENV_MODULE=python-3.13.0"
Environment="POC_PLATFORM_STATE_DIR=/opt/poc-platform/.poc_platform_dev_state"
ExecStart=/usr/bin/env bash /opt/poc-platform/poc-platform-dev/start_platform.sh
Restart=on-failure
RestartSec=10
StandardOutput=append:/opt/poc-platform/poc-platform-dev/.poc_platform.log
StandardError=append:/opt/poc-platform/poc-platform-dev/.poc_platform.log
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

등록/기동:

```bash
sudo systemctl daemon-reload
sudo systemctl start poc-platform-dev.service
# 재부팅해도 계속 떠 있게 하려면(부팅시 자동 시작):
sudo systemctl enable poc-platform-dev.service
```

운영 명령은 8100과 동일하되 서비스명만 다릅니다:

```bash
systemctl status poc-platform-dev.service
systemctl restart poc-platform-dev.service   # 코드 갱신 후 재기동
journalctl -u poc-platform-dev.service -f    # 또는 tail -f .poc_platform.log
```

`poc-platform-dev.service`는 위처럼 `POC_PLATFORM_STATE_DIR`을 `.poc_platform_dev_state/`로
지정해, `poc-platform.service`(8100)가 쓰는 `.poc_platform_state/`(가속기별 성능·비용 분석 표 등)와
**분리된 상태**로 동작합니다. dev에서 표를 편집해도 8100(운영)에는 영향을 주지 않습니다.
(2026-08-13 이전에는 이 환경변수를 지정하지 않아 두 인스턴스가 상태를 공유했습니다 — 과거 히스토리는
`HISTORY.md` 참고. `.poc_platform_dev_state/`가 아직 없다면 `.poc_platform_state/`를 복사해서
시드 데이터로 써도 됩니다: `rsync -a .poc_platform_state/ .poc_platform_dev_state/`.)

## 주요 구성

```text
backend/
  app.py          FastAPI API, run/result/report endpoint
  runner.py       run kind별 실행 dispatcher
  parser.py       실행 결과 및 로그 파싱
  state.py        run/log/GPU sample in-memory state + JSON 영속화(아래 참고)
  gpu_monitor.py  nvidia-smi/RDMA counter 기반 실시간 모니터링
  cluster.py      Warewulf/Kubernetes 관리 API
  topology.py     GPU↔NIC topology 조회

frontend/
  index.html      실제 브라우저에서 로드되는 단일 페이지(inline Babel JSX). 이 파일이 소스오브트루스.
  app.jsx         과거 스냅샷 — index.html의 inline script와 더 이상 동일하지 않음(구식/일부 기능 누락).
                  편집 대상이 아님. 신뢰하지 말 것.
  vendor/         air-gapped 환경용 frontend dependency
  assets/         InferenceX 벤치마크 정적 JSON, favicon 등

scripts/
  training/train_k8s.sh
  llmd/llmd_run.sh, llmd/llmd_serve.sh
  vllm/vllm_run.sh, vllm/vllm_bench.sh
  pd/pd_run.sh
  mlperf_*.sh
```

`state.py`가 쓰는 JSON들은 배포 폴더(`poc-platform-latest/`, `poc-platform-dev/` 등) 밖, 공통 상위 폴더의
디렉토리에 저장됩니다. 기본값은 `POC_PLATFORM_STATE_DIR` 환경변수가 없으면 `.poc_platform_state/`이며,
이 경우 **같은 상위 폴더의 모든 배포본이 공유**합니다. `poc-platform-dev.service`는 이 환경변수를
`.poc_platform_dev_state/`로 지정해 운영(latest, 8100)과 분리된 상태를 씁니다(위 "DEV/디버그 배포" 참고).
자세한 내용과 오늘 작업 히스토리는 [`HISTORY.md`](./HISTORY.md) 참고.

