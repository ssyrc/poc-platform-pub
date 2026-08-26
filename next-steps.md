# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (13회차)
- 이번 목표: **멀티노드**. 단일 노드는 8장 학습까지 통과했습니다.

---

## 1. 지금 상태

| | 상태 |
|---|---|
| 단일 노드 NCCL (1장) | 통과 |
| 단일 노드 NCCL (8장) | 통과 |
| 단일 노드 학습 llama31_8b 8장 | **통과 — 스텝 돌아감** |
| 멀티노드 | 미확인 |

원인이었던 HPC-X 플러그인은 B300에서 런처가 자동으로 끕니다 (`489dc11`).

---

## 2. 멀티노드에서 새로 걸리는 것들

단일 노드에서 **한 번도 안 쓰인 경로**가 여기서 처음 동작합니다.

| 요소 | 단일 노드 | 멀티노드 |
|---|---|---|
| NCCL 네트워크 전송 | 안 씀 (NVLink/SHM) | **씀 — IB** |
| NIC 자동 바인딩 (`NCCL_IB_HCA`) | 무의미 | **씀** |
| rendezvous (`MASTER_ADDR:PORT`) | `--standalone` | **씀** |
| 노드 간 데이터 경로 | 무관 | **양쪽에 있어야 함** |

**특히 NCCL 내장 IB 전송이 여기서 처음 실전 투입됩니다.**
HPC-X 플러그인을 껐으니 노드 간 통신은 전부 NCCL 자체 IB로 갑니다.
단일 노드에서는 이 경로가 안 쓰였기 때문에, 여기가 이번 라운드의 진짜 미지수입니다.

---

## 3. 순서 — 학습부터 돌리지 마세요

지난 2주가 그래서 길어졌습니다. 싼 것부터 갑니다.

```
2번 노드 점검  →  멀티노드 NCCL 프로브  →  멀티노드 학습
   1분              30초                    5분
```

---

## 준비

**`git pull` 필요** (`2599300` — 프로브 멀티노드 지원).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

N1=node25          # 지금까지 쓰던 노드 = rank 0
N2=<두 번째 노드 IP>
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b_pyt-blackwell.tar
```

---

## STEP 1 — 2번 노드 점검 (1분)

1번 노드는 검증됐지만 2번은 아직 아무것도 확인 안 했습니다.

```bash
./scripts/node_check.sh --host $N2 --image $IMG
```

`MISS`가 있으면 먼저 해결하세요. 특히 이 세 가지:

- **이미지가 2번 노드에도 있어야 합니다** — 없으면 `docker load -i $TAR`
- `nvidia-fabricmanager` active
- `/dev/infiniband/*` 존재, IB 링크 Active

두 노드 사이 **rendezvous 포트(기본 29500)**도 열려 있어야 합니다.

```bash
ssh $N2 "nc -zv $N1 29500" 2>&1 | tail -1     # 또는 방화벽 정책 확인
```

---

## STEP 2 — 멀티노드 NCCL 프로브 (30초, 핵심)

**이번 라운드의 본 게임입니다.** all-reduce가 실제로 네트워크를 건넙니다.

```bash
NCCL_NET_PLUGIN=none NCCL_DEBUG=INFO \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/nccl_probe.sh --hosts $N1,$N2 --image $IMG
```

성공하면 이렇게 끝납니다.

```
[probe r0] all_reduce OK (= 16)
[INFO] per-host result:
  rank 0   node25    exit=0
  rank 1   <N2>            exit=0
[INFO] multi-node NCCL OK across 2 nodes
```

`= 16`이 핵심입니다 — 16랭크가 전부 참여했다는 뜻이고, 값이 다르면 통신이 샌 겁니다.

**INFO 로그에서 볼 것**

```
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB ...   <- 어느 NIC를 골랐는지
NCCL INFO ... via NET/IB/...                  <- 노드 간 경로가 IB인지 (Socket이면 느립니다)
```

| 증상 | 손볼 곳 |
|---|---|
| rendezvous에서 멈춤 | 포트 방화벽, `MASTER_ADDR` 도달성 |
| `Socket` 경유로 붙음 | `NCCL_IB_HCA` / `NCCL_SOCKET_IFNAME` 명시 필요 |
| signal 11 | NCCL 내장 IB 문제. INFO 로그 주세요 |

NIC를 직접 지정해야 하면 이렇게 붙입니다 (프로브와 학습 양쪽 다 forward됩니다).

```bash
NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_4,mlx5_5 NCCL_SOCKET_IFNAME=bond0.3061 ...
```

---

## STEP 3 — 멀티노드 학습

프로브가 통과한 다음에만.

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_multi_node.sh --hosts $N1,$N2 \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --cp 1 --mbs 1 --gbs 256 --max-steps 10
```

**GBS가 왜 256인지**

```
WORLD = 8 GPU x 2 node = 16
DP    = WORLD / (TP x PP x CP) = 16 / 8 = 2
GBS는 MBS(1) x DP(2) = 2 의 배수여야 함
GBS=256 → grad_accum = 256 / 2 = 128
```

단일 노드(GBS=128, DP=1)와 스텝당 샘플 수를 맞추려면 256이 맞습니다.
런처가 실행 전에 이 계산을 검증하고 로그로 찍습니다.

```
[INFO] parallel: TP=8 PP=1 CP=1 -> DP=2 (world=16)
[INFO] batch:    MBS=1 GBS=256 grad_accum=128
```

**데이터는 양쪽 노드에서 같은 경로로 보여야 합니다.**
공유 스토리지면 그대로 되고, 아니면 2번 노드에도 복사해야 합니다.

```bash
ssh $N2 'ls /mgmt/server/poc-platform/data/training_llama31_8b/8b | head'
```

---

## STEP 4 — 회신

1. STEP 1 — 2번 노드 `node_check` 결과
2. STEP 2 — 프로브 통과 여부 + `NET/IB` 줄
3. STEP 3 — 학습이 스텝을 도는지

---

## 참고 — 성능은 지금 최적이 아닙니다

B300에서 HPC-X 플러그인을 껐으므로 **SHARP**(스위치 내 in-network reduction)가 빠집니다.
멀티노드 allreduce가 원래보다 느립니다. **동작에는 문제없고 벤치마크 수치만 손해입니다.**

되찾으려면 NCCL 2.28과 맞는 HPC-X가 든 이미지가 필요합니다 — 호스트 작업이 아닙니다.

정식 측정 전에 이 부분을 어떻게 할지 정하시면 됩니다. 지금은 **동작 확인이 먼저**입니다.

---

## 이 건에서 고친 것들

| 커밋 | 내용 |
|---|---|
| `d4a11f3` | llama31_8b 정밀도 — `bf16-mixed` → `bf16` |
| `19cad5e` | TP=1일 때 sequence parallelism 자동 해제 |
| `76a7fc8` | `MLPERF_TRAIN_IMAGE_TAR`로 이미지에 맞는 tar 지정 |
| `489dc11` | **B300에서 `NCCL_NET_PLUGIN=none` 기본 적용 — SIGSEGV 원인** |
| `a3d213a`, `2599300` | `nccl_probe.sh` — NCCL만 30초 검증, 단일/멀티 |

---

## 확정된 사실 (기록용)

| 항목 | 결과 |
|---|---|
| **SIGSEGV 원인** | **HPC-X `libnccl-net.so` v10 ↔ 이미지의 NCCL 2.28.3 불일치** |
| **해결** | **`NCCL_NET_PLUGIN=none`** (B300 기본값) |
| 크래시 위치 | `ncclCommInitRankConfig` 내부 |
| 최소 재현 | GPU 1장, 1랭크 |
| 드라이버 | 580.173.02 (r580) — 정상 |
| MNNVL / IMEX | 무관. `cliqueId 0x0`. 단일 노드에 IMEX 불필요 |
| `sm_103` | 무관. `sm_100` cubin이 minor 상위 호환 |
| blackwell 이미지 | `-sm90`과 동일 빌드 |
| NVSwitch fabric | 정상 |
| 호스트 NCCL / HPC-X | **컨테이너와 무관.** 이미지가 자체적으로 들고 있음 |

---

## 참고 — 정리해두면 좋은 것

`Errors`에 노드 IP, 호스트명, 사내 레지스트리 주소가 들어가 있습니다.
이 저장소는 public입니다. 원하시면 익명화해 드리겠습니다.
