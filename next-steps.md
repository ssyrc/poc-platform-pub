# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (10회차)
- 이번 결론: **GPU 1장에서도 죽습니다.** 통신 토폴로지 가설은 전부 무너졌습니다.

---

## 1. 마침내 진짜 스택이 나왔습니다

`PYTHONFAULTHANDLER=1` + `UCX_HANDLE_ERRORS=none`이 이번엔 제대로 들어갔습니다.
UCX 4프레임 대신 이게 나왔습니다.

```
Fatal Python error: Segmentation fault

  distributed_c10d.py:2826  in broadcast
  distributed_c10d.py:3630  in broadcast_object_list
  lightning/.../ddp.py:307  in broadcast
  trainer.py:1233           in log_dir
  trainer.py:1071           in __setup_profiler
```

`trainer.log_dir`이 rank 간에 경로를 맞추려고 `broadcast_object_list`를 부르고,
그게 NCCL `broadcast`로 내려가면서 죽습니다.

**이게 이 프로세스의 첫 NCCL collective입니다.** 바로 위 줄에 `NCCL version 2.28.3+cuda13.0`이
찍혀 있는데, NCCL은 communicator를 처음 만들 때 이 배너를 냅니다.
즉 **`ncclCommInitRank` 안에서 죽는 것**이 확정됐습니다.

---

## 2. 그리고 이건 1-GPU 실행입니다

```
All distributed processes registered. Starting with 1 processes
...
failed (exitcode: -11) local_rank: 0
```

**랭크가 하나입니다.** NVLink도, P2P도, NVSwitch도, 랭크 간 통신 자체가 없습니다.

지난 라운드에 제가 세운 것들이 여기서 무너집니다.

| 가설 | 상태 |
|---|---|
| 8-GPU 통신 계층 (NVLink/NVSwitch/P2P) | **폐기.** 1랭크에는 존재하지 않습니다 |
| `rank 6` 특정 GPU | **폐기.** 여기선 rank 0 |
| NVSwitch fabric | **폐기.** fabric도 정상이었고 1랭크는 안 씁니다 |
| MNNVL / IMEX | **약화.** 아래 참고 |

MNNVL만 완전히는 안 죽었습니다. NCCL은 communicator를 만들 때 world size와 무관하게
MNNVL 가용성을 **탐지**하는데, 그 탐지가 fabric 핸들 할당을 실제로 시도합니다.
1랭크여도 이 코드는 지나갑니다. 다만 "8장이라서" 라는 설명은 완전히 틀렸습니다.

**남은 그림은 훨씬 단순합니다: 이 노드에서 NCCL 2.28.3이 communicator를 못 만든다.**
NeMo도 Megatron도 TransformerEngine도 llama31_8b도 이제 용의선상에서 빠집니다.

---

## 3. 좋은 소식 — 이제 30초면 재현됩니다

1랭크로 재현된다는 건, 5분짜리 학습을 돌릴 이유가 없어졌다는 뜻입니다.
지난 커밋에 넣어둔 프로브가 정확히 이 일을 합니다. `init_process_group` + all-reduce 한 번,
그 외엔 아무것도 안 합니다.

바꿔 말하면 **한 번에 한 변수씩, 30초마다 판정**할 수 있게 됐습니다.

---

## 준비

**`git pull` 필요** (`a3d213a` — NCCL 프로브 추가).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

NODE=node25
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
```

---

## STEP 1 — 프로브 1장 + INFO 로그 (30초, 지금 제일 중요)

```bash
NCCL_DEBUG=INFO UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/nccl_probe.sh --host $NODE --image $IMG --gpus 1
```

| 결과 | 의미 |
|---|---|
| `[probe r0] ALL OK -- 1 ranks` | NCCL은 멀쩡. NeMo/Lightning 쪽으로 다시 봐야 합니다 |
| **signal 11** | **NCCL 단독 재현 확정.** 프레임워크 전부 무관 |

**`NCCL_DEBUG=INFO` 전체 로그를 꼭 주세요.** 지금까지 세 라운드째 못 받고 있는데,
이게 NCCL이 죽기 직전 어느 단계까지 갔는지 알려주는 유일한 자료입니다.

제가 볼 줄들입니다.

```
NCCL INFO Bootstrap : Using ...
NCCL INFO NET/Plugin ...
NCCL INFO cudaDriverVersion ...        <- 드라이버 버전
NCCL INFO ... MNNVL ...                <- MNNVL 탐지 여부
NCCL INFO ... CUMEM ...                <- cuMem 할당자 사용 여부
NCCL INFO comm 0x... rank 0 nranks 1 ... <- 여기까지 나오면 init은 통과
```

---

## STEP 2 — 변수 하나씩 (STEP 1이 죽었을 때, 각 30초)

STEP 1과 같은 명령에 앞에 하나씩만 더 붙입니다. 위에서부터 순서대로.

```bash
# (a) MNNVL 탐지 끄기 — fabric 핸들 경로를 안 건드리게
NCCL_MNNVL_ENABLE=0 NCCL_DEBUG=INFO ./scripts/nccl_probe.sh --host $NODE --image $IMG --gpus 1

# (b) cuMem 할당자 끄기 — (a)보다 넓게 우회
NCCL_CUMEM_ENABLE=0 NCCL_DEBUG=INFO ./scripts/nccl_probe.sh --host $NODE --image $IMG --gpus 1

# (c) NVLS 끄기
NCCL_NVLS_ENABLE=0 NCCL_DEBUG=INFO ./scripts/nccl_probe.sh --host $NODE --image $IMG --gpus 1

# (d) IB 끄기 — 1랭크엔 무관해야 정상이지만, 아니면 그것대로 정보입니다
NCCL_IB_DISABLE=1 NCCL_DEBUG=INFO ./scripts/nccl_probe.sh --host $NODE --image $IMG --gpus 1
```

**통과하는 첫 지점이 곧 원인입니다.** 통과한 변수 이름만 알려주셔도 됩니다.

---

## STEP 3 — 드라이버 버전 (ssh만, `git pull` 불필요)

이제 이게 유력 후보로 올라왔습니다. 컨테이너는 CUDA 13.0 / NCCL 2.28.3인데,
**호스트 드라이버가 그걸 받쳐주지 못하면** 정확히 이런 식으로 무너질 수 있습니다.

```bash
ssh $NODE 'nvidia-smi --query-gpu=driver_version,name,compute_cap --format=csv'
ssh $NODE 'cat /proc/driver/nvidia/version'
ssh $NODE 'nvidia-smi -q | grep -iE "cluster|clique"'
```

B300 + CUDA 13.0이면 r580 계열 이상이 필요합니다.
그보다 낮으면 **드라이버가 원인**이고, 그 경우 NCCL 변수로는 못 고칩니다.

마지막 줄(`ClusterUUID` / `CliqueId`)은 여전히 못 받았습니다.
값이 채워져 있으면 STEP 2 (a)가 유력해집니다.

---

## STEP 4 — 참고: H100은 왜 되는가

`nvidia-imex` 없이 H100이 잘 도는 건 이 가설과 모순되지 않습니다.

| | H100 (HGX) | B300 |
|---|---|---|
| MNNVL 존재 | 없음 | 있음 (NVL 랙) |
| `nvidia-smi -q`의 Fabric 섹션 | 보통 없음 / N/A | **State: Completed 로 나옴** |
| NCCL의 fabric 핸들 탐지 | 안 함 | 함 |

H100은 GPU가 fabric 소속을 광고하지 않으니 NCCL이 그 경로를 아예 안 탑니다.
그래서 IMEX가 무관한 게 당연합니다.

**다만 분명히 해둘 것:** 단일 B300 노드에 IMEX가 **필요한 게 아닙니다.**
필요하다면 설치하자는 얘기가 아니라, NCCL이 그 경로를 시도하지 않게 막자(`=0`)는 얘기입니다.
그리고 1랭크에서도 죽는 게 확인된 지금, 이 가설의 우선순위도 STEP 3보다 낮습니다.

---

## STEP 5 — 회신

`Errors`에 붙여주세요. 앞의 두 개면 대개 결론이 납니다.

1. STEP 1 — **`NCCL_DEBUG=INFO` 전체 로그** (통과했든 죽었든)
2. STEP 3 — 드라이버 버전
3. STEP 2 — 어느 변수에서 통과했는지

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| 크래시 위치 | **`ncclCommInitRank`** — `broadcast_object_list` → NCCL `broadcast` |
| 크래시 최소 조건 | **GPU 1장, 1랭크.** 통신 상대가 없어도 재현 |
| 크래시 모양 | 널 포인터 역참조 (`address not mapped ... at address (nil)`) |
| NeMo / Megatron / TE / 벤치마크 | **무관.** 1랭크 첫 collective에서 죽음 |
| 8-GPU 토폴로지 / NVLink / P2P | **무관.** 1랭크엔 존재하지 않음 |
| NVSwitch fabric | 정상 (fabricmanager active, State Completed / Success) |
| `dmesg` Xid | 없음. GPU 하드웨어 결함 아님 |
| blackwell 이미지 | `-sm90`과 동일 빌드. arch list·버전·빌드 해시 전부 같음 |
| `sm_103` | 문제 아님. `sm_100` cubin이 minor 상위 호환으로 10.3에서 동작 |
| llama31_8b 정밀도 | `bf16`만 허용 — 수정 완료(`d4a11f3`) |
| llama31_8b TP=1 | sequence parallelism 자동 해제 — 수정 완료(`19cad5e`) |
| 호스트 IB | NIC 전부 ACTIVE / link up |
| `nvidia_peermem` | 로드됨 (컨테이너 배너의 "not detected"는 오탐) |
| UCX | 원인 아님. 4프레임 백트레이스는 전역 시그널 핸들러였음 |
| 런처 코드 | `mlperf_run.sh` / `common.sh` 원본과 동일 |
| 컨테이너 인자 | `--ipc=host`, `--ulimit memlock=-1`, `--network=host`, IB 패스스루 정상 |

---

## 참고 — 정리해두면 좋은 것

`Errors`에 노드 IP(`node25`), 호스트명(`node-26049`), 사내 레지스트리
주소(`registry.internal`)가 들어가 있습니다. 이 저장소는 public입니다.
원하시면 익명화해 드리겠습니다.
