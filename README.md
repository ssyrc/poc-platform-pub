# poc-platform v6.67

POC용 Training/Inference 테스트 웹 플랫폼입니다. FastAPI backend와 React SPA frontend, 그리고 Training/Inference 실행 스크립트를 하나의 패키지로 제공합니다.

버전별 변경 내역은 [RELEASE_NOTES.md](RELEASE_NOTES.md)를 참고하세요.

## 실행 방법

### 1. 클론 및 실행 권한 부여

```bash
git clone https://github.com/ssyrc/poc-platform.git
cd poc-platform
chmod +x start_platform.sh scripts/*.sh scripts/*/*.sh
```

### 2. 환경 설정

사내 endpoint, registry credential, 개인 경로 등 site-specific 값은 Git에 올리지 않습니다.

```bash
cp .env.example .env
vi .env
```

`.env`는 `start_platform.sh`와 `scripts/common.sh`가 자동으로 로드하며 `.gitignore`에 포함되어 있습니다.
다른 경로의 파일을 쓰려면 `POC_PLATFORM_ENV_FILE=/path/to/env`로 지정합니다.

### 3. 기동

```bash
./start_platform.sh
```

`start_platform.sh`는 Python 3.9 이상을 탐지하고, `./.venv`를 생성한 뒤(idempotent)
`files/` wheelhouse에서 오프라인으로 의존성을 설치하고 uvicorn을 띄웁니다.

기본 접속 주소:

```text
http://<서버IP>:8089
```

### 주요 실행 옵션

```bash
PORT=9000 ./start_platform.sh              # 포트 변경 (기본 8089)
HOST_BIND=127.0.0.1 ./start_platform.sh    # bind 주소 변경 (기본 0.0.0.0)
SKIP_PIP_INSTALL=1 ./start_platform.sh     # 의존성 설치 단계 생략
WHEELHOUSE=/abs/path ./start_platform.sh   # wheelhouse 경로 지정
POC_PLATFORM_ROOT=/data/poc-platform ./start_platform.sh  # 데이터 루트 지정
MLPERF_PYTHON=python3.11 ./start_platform.sh              # Python 인터프리터 지정
```

포그라운드로 동작하며 Ctrl-C로 종료합니다. 데몬 모드는 없으므로 상시 운영에는 아래 systemd 구성을 사용합니다.

## systemd 운영 배포

`start_platform.sh`는 마지막에 `exec`로 uvicorn을 실행하므로 systemd가 uvicorn 프로세스를 직접 추적합니다.
별도의 wrapper나 PID 파일이 필요하지 않습니다.

### 1. 설치 위치 준비

```bash
sudo mkdir -p /opt/poc-platform
sudo cp -a poc-platform/. /opt/poc-platform/
cd /opt/poc-platform
sudo chmod +x start_platform.sh scripts/*.sh scripts/*/*.sh
sudo cp .env.example .env && sudo vi .env
```

### 2. venv 사전 생성

서비스 등록 전에 한 번 수동 실행해 `.venv`와 의존성을 만들어 둡니다.
이렇게 하면 서비스 유닛에서 `SKIP_PIP_INSTALL=1`로 기동 시간을 줄일 수 있습니다.

```bash
sudo ./start_platform.sh   # 정상 기동 확인 후 Ctrl-C
```

### 3. 유닛 파일 작성

`/etc/systemd/system/poc-platform.service`:

```ini
[Unit]
Description=POC Bench Platform
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/poc-platform
Environment=PORT=8089
Environment=HOST_BIND=0.0.0.0
Environment=SKIP_PIP_INSTALL=1
ExecStart=/opt/poc-platform/start_platform.sh
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillMode=control-group
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

`User=root`인 이유는 플랫폼이 compute node에 root로 SSH 접속하고(`K8S_SSH_USER` 기본값 root),
Docker와 `/etc/kubernetes/admin.conf`를 사용하기 때문입니다. 별도 계정으로 운영하려면
해당 계정에 docker 그룹, kubeconfig 읽기 권한, 노드 SSH 키가 준비되어 있어야 합니다.

`.env`는 `start_platform.sh`가 직접 로드하므로 `EnvironmentFile` 지시자는 필요하지 않습니다.
`KillMode=control-group`은 서비스 종료 시 backend가 띄운 launcher 자식 프로세스까지 함께 정리합니다.

### 4. 서비스 등록 및 기동

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now poc-platform
sudo systemctl status poc-platform
```

### 5. 운영 커맨드

```bash
sudo journalctl -u poc-platform -f        # 실시간 로그
sudo systemctl restart poc-platform       # 재기동
sudo systemctl stop poc-platform          # 중지
```

### 6. 버전 업그레이드

```bash
sudo systemctl stop poc-platform
sudo cp -a poc-platform-v<new>/. /opt/poc-platform/
cd /opt/poc-platform && sudo SKIP_PIP_INSTALL=0 ./start_platform.sh   # 의존성 갱신 후 Ctrl-C
sudo systemctl start poc-platform
```

실행 history와 dashboard 데이터(`runs.json`, `dashboard.json`)는 설치 디렉터리가 아니라
**그 상위 디렉터리**의 `.poc_platform_state/`에 저장됩니다. 버전 폴더를 통째로 교체해도
데이터가 남도록 의도된 동작입니다.

```text
/opt/poc-platform/            # 설치 디렉터리
/opt/.poc_platform_state/     # runs.json, dashboard.json
```

설치 위치를 옮길 때는 이 상태 디렉터리도 함께 옮겨야 합니다.
경로를 고정하려면 유닛 파일에 `Environment=POC_PLATFORM_STATE_DIR=/var/lib/poc-platform`을
추가하세요. 구버전에서 쓰던 설치 디렉터리 내부의 `.platform_state/`는 읽기 fallback으로만
사용되며, 새로 저장되지는 않습니다.

## 구성

```text
backend/
  app.py          FastAPI API, run/result/report endpoint
  runner.py       run kind별 실행 dispatcher
  parser.py       실행 결과 및 로그 파싱
  state.py        run/log/GPU sample state 및 영속화
  gpu_monitor.py  nvidia-smi/RDMA counter 기반 실시간 모니터링
  cluster.py      Warewulf/Kubernetes 관리 API
  topology.py     GPU↔NIC topology 조회
  requirements.txt

frontend/
  index.html      실제 브라우저에서 로드되는 React SPA
  app.jsx         index.html inline JSX와 동일한 원본
  assets/         favicon 및 플랫폼 아이콘
  vendor/         air-gapped 환경용 frontend dependency

scripts/
  common.sh                 공통 helper (.env 로드, 원격 kubectl 등)
  mlperf_run.sh             MLPerf 실행 진입점
  mlperf_train_v41.sh       MLPerf Training v4.1
  mlperf_train_v51.sh       MLPerf Training v5.1
  mlperf_infer_v51.sh       MLPerf Inference v5.1
  mlperf_infer_v60.sh       MLPerf Inference v6.0
  training/train_k8s.sh     Kubernetes Training Job
  vllm/vllm_run.sh          vLLM Single Instance 실행
  vllm/vllm_bench.sh        vLLM 벤치마크
  vllm/sglang_bench.sh      SGLang 벤치마크
  pd/pd_run.sh              PD Disaggregation 실행
  pd/pd_serve_vllm.sh       PD prefill/decode vLLM serve
  pd/pd_serve_sglang.sh     PD prefill/decode SGLang serve
  llmd/llmd_run.sh          llm-d 실행
  llmd/llmd_serve.sh        llm-d serve
  cluster/k8s_status.sh     K8s 클러스터 상태 조회
  cluster/k8s_join_worker.sh  worker node join

start_platform.sh           플랫폼 기동 스크립트
.env.example                site-specific 설정 템플릿
```
