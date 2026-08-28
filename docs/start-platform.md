# 플랫폼 띄우고 테스트하기

`start_platform.sh` 로 플랫폼을 올리고, 브라우저에서 실제 run 을 돌려 확인하는 순서입니다.
노드 자체 점검은 `node_check.sh` / `nccl_probe.sh` 로 따로 합니다(5절 참고).

---

## 0. 배치와 `.env`

배포 폴더 안에서 다 끝납니다. `.env` 는 `start_platform.sh` 와 `scripts/common.sh` 가
**둘 다** `set -a` 로 읽으므로, 여기 넣은 값은 백엔드와 벤치 스크립트 양쪽에 그대로 갑니다.

```bash
cd /opt/poc-platform/poc-platform-latest
cp .env.example .env
vi .env
```

최소로 확인할 항목:

| 키 | 뜻 | 안 넣으면 |
|---|---|---|
| `POC_PLATFORM_ROOT` | 데이터/wheelhouse 기준 경로 | 배포 폴더 자신 |
| `MLPERF_DATA_ROOT` | 결과 트리 + `dockerimgs/` | `$POC_PLATFORM_ROOT/data` |
| `WHEELHOUSE` | 폐쇄망 pip 휠 | `$POC_PLATFORM_ROOT/files` |
| `MLPERF_LOG_ROOT` | run 로그가 쌓이는 곳 | `$POC_PLATFORM_ROOT` |
| `MLPERF_HOSTFILE` | CLI 기본 hostfile | 없음 (플래그로 지정) |
| `MLPERF_NET_H_HPC_JUMP` | H HPC센터 경유 체인 | H망 노드에 붙지 못함 |

**H B300 을 쓰려면** 이 두 줄이 반드시 있어야 합니다. 플랫폼(S, `platform`)에서
`node*` 로 바로 가는 경로가 없고, bastion 두 단을 거쳐야 합니다.

```bash
MLPERF_NET_H_HPC_JUMP=root@bastion1,root@bastion2
MLPERF_NET_H_HPC_SSH_OPTS=-o ConnectTimeout=20
```

주소는 `.env` 에만 있고 UI 는 `h_hpc` 이라는 id 만 보냅니다. 브라우저와 run 히스토리에
IP 가 남지 않습니다.

체인이 먼저 손으로 뚫리는지부터 확인하세요. 여기서 막히면 UI 에서도 똑같이 막힙니다.

```bash
ssh -J root@bastion1,root@bastion2 root@node26 hostname
```

---

## 1. 기동

### 1-1. 손으로 (dev / 처음 올릴 때)

```bash
cd /opt/poc-platform/poc-platform-latest
chmod +x start_platform.sh scripts/*.sh scripts/*/*.sh
PORT=8101 ./start_platform.sh
```

스크립트가 순서대로 하는 일 — 이 순서대로 로그가 나옵니다.

1. `module load python-3.13.0` (없으면 그냥 넘어감, `MLPERF_ENV_MODULE=` 로 끔)
2. Python ≥ 3.9 탐색 → `MLPERF_PYTHON` 이 우선
3. `mlperf_run.sh` 등 **필수 5개 스크립트** 확인 → 없으면 여기서 종료
4. `.venv` 생성 (`bin/activate` 빠진 반쪽 venv 면 지우고 재생성)
5. wheelhouse 에서 `--no-index` 로 설치 → `SKIP_PIP_INSTALL=1` 로 건너뜀
6. `import fastapi/uvicorn/pydantic/sse_starlette` 확인
7. `uvicorn backend.app:app` 기동

Ctrl-C 로 끝납니다. daemon 모드는 없습니다 — 계속 띄우려면 systemd 를 쓰세요.

자주 쓰는 조합:

```bash
SKIP_PIP_INSTALL=1 PORT=8101 ./start_platform.sh    # 의존성 이미 깔린 재기동, 가장 빠름
MLPERF_RELOAD=1  PORT=8101 ./start_platform.sh      # 코드 고치면서 볼 때 (--reload)
MLPERF_PYTHON=/apps/python/Python-3.13.0/bin/python3 ./start_platform.sh
```

**기본 포트는 8089** 입니다. 운영(8100)/dev(8101)는 systemd 가 `PORT` 를 넣어 주는 값이므로,
손으로 띄울 때는 `PORT` 를 직접 줘야 같은 포트로 뜹니다.

### 1-2. systemd (운영 8100 / dev 8101)

유닛 파일 전문은 [README](../README.md#운영-배포-systemd) 에 있습니다.

```bash
systemctl restart poc-platform.service       # 8100, poc-platform-latest/
systemctl restart poc-platform-dev.service   # 8101, poc-platform-dev/
systemctl status  poc-platform.service
journalctl -u poc-platform.service -f        # 또는 tail -f .poc_platform.log
```

dev 는 `POC_PLATFORM_STATE_DIR=.poc_platform_dev_state` 로 운영과 상태가 분리돼 있습니다.
dev 에서 표를 고쳐도 8100 에는 영향이 없습니다.

### 1-3. 브라우저로 접근

플랫폼이 사내망 안에 있으면 로컬로 포워딩합니다.

```bash
# S 슈퍼컴 로그인 노드를 거쳐 (평소)
ssh -J <로그인노드> -L 8100:localhost:8100 root@platform

# 플랫폼 자체가 H망 뒤에 있을 때
ssh -J root@bastion1,root@bastion2 -L 8100:localhost:8100 root@bastion2
```

그리고 `http://localhost:8100`.

> 포워딩은 **브라우저가 플랫폼에 닿는 문제**입니다. 플랫폼이 GPU 노드에 닿는 경로는
> 별개이고, 그건 `.env` 의 `MLPERF_NET_*_JUMP` 가 담당합니다. 둘을 섞지 마세요.

---

## 2. 떴는지 확인 (30초)

```bash
curl -s localhost:8100/api/health
# {"ok":true,"backend_started_at":...}

curl -s localhost:8100/api/config | python3 -m json.tool | head -40
```

`/api/config` 에서 봐야 할 것:

- `scripts_dir` — `.../scripts` 를 가리키는지 (다른 배포본을 보고 있으면 여기서 드러납니다)
- `mlperf_root`, `data_root` — `.env` 대로인지
- `state_dir` — 운영/dev 가 섞이지 않았는지
- `supported.mlperf` — `training:v5.1` 에 `llama2_70b_lora`, `llama31_8b` 와 `B300` 이 있는지

관리 서버 쪽 준비물(데이터 루트, 이미지 tar)은 따로 한 번에 봅니다. 이건 읽기만 하고
컨테이너를 띄우지 않습니다.

```bash
./scripts/preflight.sh                # 전체
./scripts/preflight.sh training v5.1  # 하나만
```

---

## 3. UI 에서 테스트 (이 순서대로)

### 3-1. network 고르기

MLPerf 탭 맨 위 `network` 버튼 — **S 슈퍼컴망**(기본, 직접 접속) / S DDZ망(미구성) /
**H HPC센터**(경유 접속). 고른 값은 브라우저에 기억되고, run 을 걸면
`MLPERF_NETWORK` 로 넘어가 모든 호스트의 ssh 경로를 정합니다. B300 노드를 쓸 거면
반드시 **H HPC센터**로 바꾸세요. 여기가 틀리면 다음 단계에서 GPU 타입 탐지부터 실패합니다.

### 3-2. hosts 넣고 GPU 타입이 잡히는지 보기

`hosts` 에 노드를 넣으면 프론트가 `/api/hosts/{host}/gpu_type` 을 부릅니다. `B300` 이
떠야 정상입니다 — 이게 뜬다는 것은 **선택한 network 로 그 노드에 ssh 가 실제로 붙었다**는
뜻이라, 여기까지가 사실상 연결 테스트입니다.

CLI 로 같은 걸 확인하려면:

```bash
curl -s localhost:8100/api/hosts/node26/gpu_type
```

(이 엔드포인트는 UI 선택과 무관하게 `.env` 의 `MLPERF_SSH_JUMP` / 기본 network 를 씁니다.
`h_hpc` 만 설정된 상태에서 CLI 로 확인하려면 `MLPERF_SSH_JUMP` 를 쓰세요.)

### 3-3. dry-run 먼저

benchmark / GPU 타입 / 노드 수를 정한 뒤 **dry-run 을 켜고** 한 번 돌립니다.
컨테이너를 띄우지 않고 조립된 명령만 찍으므로, 로그에서 이걸 봅니다:

- `--nnodes` 가 넣은 노드 수와 같은지
- `MASTER_ADDR` 가 rank 0 노드인지
- `GBS = MBS × DP × grad_accum` 이 노드 수에 맞게 유도됐는지
  (GBS 를 비워 두면 `[INFO] GBS not given; derived ...` 줄이 나옵니다)
- docker image 이름과 tar 경로

### 3-4. 실제 run

dry-run 을 끄고 돌립니다. 로그 스트림(`/api/runs/{id}/logs/stream`)이 SSE 로 붙어
호스트별 출력이 실시간으로 흐릅니다. 컨테이너 전체 출력은 노드의
`$MLPERF_LOG_ROOT/mlperf_logs_train_v51/<run>/container.log` 에 그대로 쌓입니다
(step 로그가 `run.log` 에서 잘리던 문제는 이 경로로 해결된 상태입니다).

권장 순서 — 한 단계씩 올려야 실패 지점이 분명합니다.

1. **1노드** `llama31_8b`, TP=1 (SP 는 스크립트가 알아서 끕니다)
2. **2노드** 같은 벤치마크 — 여기서 rendezvous / NCCL 이 걸러집니다
3. 그 다음에 노드 수를 늘리거나 `llama2_70b_lora` 로

### 3-5. 결과

- `Recent Runs` → run 클릭 → 로그 / 결과 / GPU 샘플
- 리포트: `http://localhost:8100/api/runs/<run_id>/report` (HTML)
- run 목록: `curl -s localhost:8100/api/runs | python3 -m json.tool`

---

## 4. API 로만 돌리기 (UI 없이 확인할 때)

```bash
curl -s -X POST localhost:8100/api/runs \
  -H 'content-type: application/json' \
  -d '{
        "kind": "mlperf",
        "suite": "training",
        "version": "v5.1",
        "benchmark": "llama31_8b",
        "gpu_type": "B300",
        "hosts": ["node26"],
        "dry_run": true,
        "params": { "args": { "MLPERF_NETWORK": "h_hpc", "NUM_GPUS": "8", "TP": "1" } }
      }' | python3 -m json.tool
```

`params.args` 는 모든 호스트의 환경에 합쳐지고, `params.args_by_host` 로 호스트별로
덮어쓸 수 있습니다. UI 가 network 버튼으로 보내는 것도 정확히 이 `MLPERF_NETWORK` 한 줄입니다.

```bash
RUN=<응답의 run_id>
curl -s localhost:8100/api/runs/$RUN | python3 -m json.tool
curl -s localhost:8100/api/runs/$RUN/logs | tail -50
curl -s -X POST localhost:8100/api/runs/$RUN/stop
```

---

## 5. 안 될 때

| 증상 | 원인 | 할 것 |
|---|---|---|
| `no Python >= 3.9` | module 미로드 | `module load python-3.13.0` 또는 `MLPERF_PYTHON=` 지정 |
| `venv is incomplete (no bin/activate)` | module 없이 venv 생성됨 | `rm -rf .venv` 후 module 로드하고 재기동 |
| `wheelhouse not found` | `WHEELHOUSE` 경로 틀림 | `.env` 수정, 또는 `SKIP_PIP_INSTALL=1` |
| `missing required mlperf script` | `MLPERF_SCRIPTS_DIR` 가 다른 배포본 | `/api/config` 의 `scripts_dir` 확인 |
| 포트 이미 사용 중 | 8100 에 이미 systemd 인스턴스 | `systemctl status poc-platform.service`, 또는 다른 `PORT` |
| GPU 타입이 안 잡힘 | network 선택 틀림 / 체인 미설정 | `ssh -J ...` 로 직접 확인, `.env` 의 `MLPERF_NET_*_JUMP` |
| Recent Runs 가 비어 있음 | state 디렉토리가 갈림 | `/api/config` 의 `state_dir`, dev 는 `.poc_platform_dev_state/` |
| run 이 `exit=1` 로만 끝남 | 인자 누락 | dry-run 으로 조립된 명령 확인 → `preflight.sh` |

노드 쪽이 의심되면 플랫폼이 아니라 스크립트로 좁히세요.

```bash
./scripts/node_check.sh --host node26
./scripts/node_diff.sh  --hosts-file hostfile     # 노드 간 차이만 출력
./scripts/acs_check.sh  --host node26       # PCIe ACS redirect
./scripts/nccl_probe.sh --hosts-file hostfile --image <repo:tag>
```
