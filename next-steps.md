# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (9회차)
- 이번 가설: **NCCL이 MNNVL(멀티노드 NVLink) 경로를 타는데 IMEX가 없어서 죽는다**

---

## 1. fabric 결과 해석

| 항목 | 결과 | 판정 |
|---|---|---|
| `nvidia-fabricmanager` | active | 정상 |
| `nvidia-smi -q` fabric | State: Completed / Status: Success | 정상 |
| `dmesg` | Xid 없음 | 정상 |
| `nvidia-imex` | **inactive** | 아래 참고 |

**노드 안 NVSwitch는 멀쩡합니다.** 하드웨어·드라이버 쪽은 이걸로 거의 정리됐습니다.
`dmesg`에 Xid가 없다는 것도 큽니다 — GPU 하드웨어 결함이 아니라는 뜻이고,
`rank 6` 가설도 사실상 여기서 닫힙니다.

### IMEX가 inactive인 건 그 자체로는 정상입니다

IMEX(Internode Memory Exchange)는 **NVLink가 노드 경계를 넘을 때**만 필요합니다.
GB200/GB300 NVL 랙처럼요. 단일 HGX B300 8-GPU 노드에서는 안 떠 있는 게 기본입니다.

**문제는 NCCL이 그걸 모른다는 데 있습니다.**

---

## 2. 왜 이게 유력한가

크래시 신호를 다시 보면:

```
Caught signal 11 (Segmentation fault: address not mapped to object at address (nil))
```

`at address (nil)` — **널 포인터 역참조**입니다. 메모리 침범이나 스택 손상이 아니라,
"받아온 핸들이 NULL인데 그대로 갖다 썼다"는 전형적인 모양입니다.

그리고 죽는 자리가 `NCCL version 2.28.3+cuda13.0` 출력 직후, 즉 **communicator 초기화**입니다.

NCCL 2.28은 Blackwell에서 fabric 핸들(`CU_MEM_HANDLE_TYPE_FABRIC`)로 메모리를 잡으려
시도합니다. 이 경로는 **IMEX가 떠 있어야** 동작합니다. IMEX가 없으면 드라이버가 실패를
돌려주는데, NCCL이 그 반환값을 확인하지 않고 쓰면 정확히 위 모양의 SIGSEGV가 납니다.

세 가지가 다 들어맞습니다 — 널 역참조 / NCCL init 직후 / IMEX 없음.

**노드와 벤치마크를 바꿔도 재현된 것도 설명됩니다.** 두 노드 다 같은 구성이니까요.

---

## 준비

`git pull`은 **제가 코드를 고쳤다고 적은 라운드에만** 하시면 됩니다.
필요한 STEP에는 커밋 번호와 함께 표시해 두겠습니다.

```bash
cd /mgmt/server/poc-platform/poc-platform-pub

NODE=node25
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b_pyt-blackwell.tar
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
```

---

## STEP 1 — MNNVL 끄고 8장 (이번 라운드의 본 게임)

**`git pull` 필요** (`19f5375` — `NCCL_MNNVL_ENABLE` forward 추가).

바꾸는 변수는 `NCCL_MNNVL_ENABLE=0` 하나뿐입니다. 통과하면 원인 확정입니다.

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= \
NCCL_DEBUG=INFO \
NCCL_MNNVL_ENABLE=0 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 5
```

| 결과 | 결론 |
|---|---|
| **스텝이 돈다** | **원인 확정.** 런처에 기본값으로 넣겠습니다 |
| 여전히 signal 11 | MNNVL 아님 → STEP 2. 대신 `NCCL_DEBUG=INFO` 로그가 남습니다 |

`NCCL_DEBUG=INFO`를 켜둔 이유는, 실패해도 **NCCL이 죽기 직전까지 뭘 하려 했는지**가
로그에 남기 때문입니다. 성공하든 실패하든 이 로그는 꼭 주세요.

**INFO 로그에서 제가 볼 것** (미리 찾아보셔도 좋습니다)

```
NCCL INFO ... MNNVL ...          <- MNNVL을 감지했는지
NCCL INFO ... cuMem ...          <- fabric 핸들을 잡으려 했는지
NCCL INFO ... NVLS ...           <- multicast 경로를 켰는지
NCCL INFO Bootstrap : Using ...  <- 마지막으로 성공한 단계
```

---

## STEP 2 — 그래도 죽으면 (같은 계열, 한 단계 더 아래)

STEP 1과 같은 명령에서 변수만 바꿉니다. 위에서 아래로 하나씩.

```bash
# (a) cuMem 할당자 자체를 끄기 — fabric 핸들 경로를 통째로 우회
NCCL_CUMEM_ENABLE=0

# (b) NVLS(NVSwitch multicast) 끄기
NCCL_NVLS_ENABLE=0

# (c) P2P 직결 끄기 — 가장 둔한 방법. 이걸로도 죽으면 NCCL 밖의 문제
NCCL_P2P_DISABLE=1
```

어느 지점에서 통과하는지가 곧 원인입니다.

---

## STEP 3 — 1-GPU (STEP 1·2가 다 실패했을 때만)

**`git pull` 필요** (`19cad5e` — TP=1 sequence parallelism 자동 해제).
STEP 1을 위해 이미 pull 하셨으면 그대로 됩니다.

NCCL·NVLink·P2P를 전부 빼고 돌립니다. 여기서도 죽으면 NCCL 문제가 아닙니다.

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
TORCH_SHOW_CPP_STACKTRACES=1 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama31_8b --docker-image $IMG \
  --gpus 1 --tp 1 --pp 1 --mbs 1 --gbs 8 --max-steps 5
```

---

## STEP 4 — 곁들여 확인 (ssh만, `git pull` 불필요)

GPU가 MNNVL 소속이라고 **광고하고 있는지**를 봅니다. 이게 있으면 NCCL이 속을 만합니다.

```bash
ssh $NODE 'nvidia-smi -q | grep -iE "cluster|clique|fabric" '
```

`ClusterUUID`나 `CliqueId`에 값이 채워져 있으면 STEP 1 가설이 더 굳어집니다.
(지난번엔 State/Status만 주셔서 이 두 줄을 못 봤습니다.)

---

## STEP 5 — 아직 못 받은 것

8-GPU SIGSEGV 로그가 UCX 백트레이스 4줄에서 잘려 있습니다.
그 뒤 torchrun 블록이 **어느 rank가 죽었는지** 알려줍니다.

```
Root Cause (first observed failure):
  [0]: ... local_rank: N (pid: ...) ... exitcode: -11
```

`dmesg`에 Xid가 없다는 걸로 하드웨어 가설은 거의 닫혔지만,
전 랭크가 죽는지 한 랭크만 죽는지는 여전히 다른 이야기입니다.

---

## STEP 6 — 회신

`Errors`에 붙여주세요.

1. STEP 1 — 통과 여부 + **`NCCL_DEBUG=INFO` 로그** (제일 중요)
2. STEP 2 — 했다면 어느 변수에서 통과했는지
3. STEP 4 — `ClusterUUID` / `CliqueId`
4. STEP 5 — torchrun `Root Cause` 블록

---

## 이번에 코드에 고친 것

`NCCL_MNNVL_ENABLE`을 env allowlist(호스트→원격, 원격→컨테이너 양쪽)에 추가했습니다.
`mlperf_train_v51.sh`, `mlperf_train_v41.sh` 둘 다입니다.

STEP 1이 통과하면 이 값을 B300 기본값으로 넣겠습니다. 지금은 임의로 바꾸지 않았습니다 —
아직 가설이라, 검증 전에 기본 동작을 바꾸고 싶지 않습니다.

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| NVSwitch fabric | **정상.** fabricmanager active, State Completed / Success |
| `dmesg` Xid | **없음.** GPU 하드웨어 결함 아님 |
| `nvidia-imex` | inactive — 단일 노드에선 정상이나 NCCL이 오인할 여지 있음 |
| blackwell 이미지 | `-sm90`과 동일 빌드. arch list·버전·빌드 해시 전부 같음 |
| `sm_103` | **문제 아님.** `sm_100` cubin이 minor 상위 호환으로 10.3에서 동작 |
| llama31_8b 정밀도 | `bf16`만 허용 — 수정 완료(`d4a11f3`), 통과 확인 |
| llama31_8b TP=1 | sequence parallelism 자동 해제 필요 — 수정 완료(`19cad5e`) |
| llama2_70b_lora 정밀도 | `trainer.precision`을 안 읽음. `bf16-mixed`여도 무해 |
| 크래시 지점 | NCCL communicator 초기화. 모델 커널 실행 전 |
| 크래시 모양 | 널 포인터 역참조 (`address not mapped ... at address (nil)`) |
| 크래시 재현 범위 | 벤치마크·노드를 바꿔도 동일 (이미지는 애초에 안 바뀌었음) |
| GPU compute capability | 10.3 (`sm_103`) |
| 호스트 IB | NIC 전부 ACTIVE / link up |
| `nvidia_peermem` | 로드됨 (컨테이너 배너의 "not detected"는 오탐) |
| 컨테이너 UCX | `mlx5_0`~`mlx5_15`, `cuda_cpy`, `cuda_ipc` 전부 정상 인식 |
| UCX transport | 원인 아님. 4프레임 백트레이스는 UCX의 전역 시그널 핸들러 |
| 런처 코드 | `mlperf_run.sh` / `common.sh` 원본과 동일 |
| 컨테이너 인자 | `--ipc=host`, `--ulimit memlock=-1`, `--network=host`, IB 패스스루 정상 |

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP(`node25`), 호스트명(`node-26049`), 사내 레지스트리
주소(`registry.internal`)가 들어가 있습니다. 이 저장소는 public입니다.
원하시면 익명화해 드리겠습니다.
