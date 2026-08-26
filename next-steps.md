# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (7회차)
- 이번 목표: SIGSEGV가 **아키텍처 문제인지 통신 문제인지** 한 번에 가르기

---

## 1. 질문에 먼저 답하면 — `sm_103` 때문은 아닐 가능성이 큽니다

**이유 1. 증상이 다릅니다.**

커널에 맞는 cubin도 PTX도 없으면 CUDA는 segfault가 아니라 명시적 에러를 냅니다.

```
CUDA error: no kernel image is available for execution on the device
```

`sm_103` 부재였다면 이 문장이 Python 예외로 떴어야 합니다. signal 11이 아니라요.

**이유 2. 죽은 지점이 너무 이릅니다.**

이번 로그는 여기까지 갔습니다.

```
All distributed processes registered. Starting with 8 processes
NCCL version 2.28.3+cuda13.0
[Gloo] Rank 0 is connected to 0 peer ranks ...        <- 여기까지 정상
Caught signal 11 (Segmentation fault: address not mapped to object at address (nil))
```

**모델 커널이 한 번도 안 돈 상태입니다.** 분산 초기화 / NCCL 부트스트랩 구간이고,
TransformerEngine의 `sm_103a` 커널은 아직 호출되지도 않았습니다.
아키텍처 미스매치가 여기서 터질 자리가 아닙니다.

**다만 100%는 아닙니다.** TE/cuDNN/cuBLASLt처럼 arch로 함수 포인터를 고르는 라이브러리가
못 찾은 채 null을 그대로 역참조하면 segfault가 날 수는 있습니다. 그래서 아래 STEP 1로
확인만 하고 넘어갑니다. (아직 `get_arch_list()` 결과를 못 받았습니다.)

---

## 2. 이번 실행에서 진짜 중요한 것

**정밀도 수정은 통했습니다.** MLLOG가 다 찍히고, 모델이 만들어지고, 8개 프로세스가 전부
분산 등록까지 끝냈습니다. 이전보다 훨씬 멀리 갔습니다.

그리고 이제 크래시 지점이 **벤치마크·이미지·노드를 바꿔도 같은 자리**입니다.

| | 1차 | 2차 | 이번 |
|---|---|---|---|
| 벤치마크 | llama2_70b_lora | llama2_70b_lora | **llama31_8b** |
| 이미지 | `-sm90` | `-sm90` | **blackwell** |
| 노드 | `-26043` | `-26043` | **`-26049`** |
| 죽은 자리 | NCCL 초기화 직후 | NCCL 초기화 직후 | NCCL 초기화 직후 |

세 변수를 다 바꿨는데 같은 자리에서 죽습니다.
**벤치마크 문제도, 이미지 문제도, 특정 GPU 문제도 아니라는 뜻입니다.**
남는 건 8-GPU 통신 계층(NVLink / NVSwitch / P2P) 또는 노드 공통 설정입니다.

`rank 6` 가설은 이걸로 약해졌습니다. 다른 노드에서도 났으니까요.
(단, 이번엔 어느 rank가 죽었는지 로그가 잘려서 확인이 안 됩니다 — STEP 4 참고)

---

## 3. UCX 핸들러가 또 떴습니다

```
0  libucs.so.0(ucs_handle_error+0x2e4)
```

이게 보인다는 건 `UCX_HANDLE_ERRORS=none`이 **컨테이너까지 안 갔다**는 뜻입니다.
전달됐다면 UCX는 핸들러를 안 걸고, 대신 진짜 Python 스택이 나왔어야 합니다.

아래 명령들은 `UCX_ERROR_SIGNALS=`(빈 값)도 같이 겁니다. 이쪽이 더 확실합니다.

---

## 준비

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

NODE=node25
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b_pyt-blackwell.tar
IMG=<docker images로 확인한 REPOSITORY:TAG>
```

---

## STEP 1 — 아직 안 주신 두 가지 (10초)

이거 없이는 `sm_103` 얘기를 매번 추측으로 하게 됩니다.

```bash
ssh $NODE 'docker images | grep -i llama31_8b'
ssh $NODE "docker run --rm --gpus all $IMG python -c 'import torch; print(torch.cuda.get_arch_list())'"
```

`sm_103`이 **있으면** 아키텍처 가설은 완전히 종료입니다.
**없어도** 위 1번 이유 때문에 이번 크래시의 원인은 아닐 가능성이 큽니다.

---

## STEP 2 — 핵심: GPU 1장으로 돌리기 (가장 중요)

**이 한 번이 아키텍처와 통신을 갈라줍니다.** 1장이면 NCCL도 NVLink도 P2P도 안 씁니다.

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
TORCH_SHOW_CPP_STACKTRACES=1 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama31_8b --docker-image $IMG \
  --gpus 1 --tp 1 --pp 1 --mbs 1 --gbs 8 --max-steps 5
```

| 결과 | 결론 | 다음 |
|---|---|---|
| **돈다** | 통신 계층 문제 확정. 아키텍처·이미지 무관 | STEP 3 |
| **또 signal 11** | 통신 무관. 라이브러리/드라이버 문제 | STEP 5의 스택으로 지점 특정 |

---

## STEP 3 — NCCL 경로를 하나씩 끄기 (STEP 2가 통과했을 때)

새로 forward되게 만든 변수들입니다. `git pull` 후에 동작합니다.

```bash
# (a) P2P(NVLink 직결) 끄고 8장
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= NCCL_DEBUG=INFO \
NCCL_P2P_DISABLE=1 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 5

# (b) NVLS(NVSwitch multicast) 끄고 8장 — Blackwell에서 흔한 지점입니다
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= NCCL_DEBUG=INFO \
NCCL_NVLS_ENABLE=0 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 5
```

둘 중 하나로 통과하면 원인이 그 경로로 좁혀집니다.
`NCCL_DEBUG=INFO`는 NCCL이 어디까지 갔는지 보여주니 로그를 꼭 같이 주세요.

---

## STEP 4 — NVSwitch / fabric 상태 (B300이라 확인 필요, 30초)

NVSwitch 기반 8-GPU 노드에서 **fabricmanager가 안 떠 있으면** GPU 간 P2P가 깨진 채로
초기화가 진행되다 죽습니다. 증상이 정확히 이 자리입니다.

```bash
ssh $NODE 'systemctl is-active nvidia-fabricmanager; systemctl is-active nvidia-imex'
ssh $NODE 'nvidia-smi -q | grep -iA6 "fabric"'
ssh $NODE 'nvidia-smi topo -m'
ssh $NODE 'dmesg | grep -iE "xid|nvrm|nvswitch" | tail -30'
```

`fabricmanager`가 `inactive`거나 fabric state가 `Completed`가 아니면 **거기가 원인**입니다.

---

## STEP 5 — 잘린 로그 채우기

지금 붙여주신 로그는 UCX 백트레이스 4줄에서 끝나 있습니다.
그 뒤에 torchrun이 찍는 요약이 **어느 rank가 죽었는지** 알려주는 부분입니다.

```
Root Cause (first observed failure):
  [0]: ... local_rank: N (pid: ...) ... exitcode: -11
```

이 블록을 `Errors`에 같이 넣어주세요. 이게 있어야 `rank 6` 가설을 완전히 접거나
되살릴 수 있습니다.

---

## STEP 6 — 회신

`Errors`에 붙여주세요.

1. STEP 1 — 이미지 태그 + `get_arch_list()`
2. STEP 2 — **1-GPU가 도는지** (이게 제일 중요합니다)
3. STEP 3 — 했다면 어느 쪽이 통과했는지 + `NCCL_DEBUG=INFO` 로그
4. STEP 4 — fabricmanager / fabric state
5. STEP 5 — torchrun의 `Root Cause` 블록

---

## 이번에 코드에 추가한 것

`NCCL_P2P_DISABLE`, `NCCL_SHM_DISABLE`, `NCCL_NVLS_ENABLE`, `NCCL_CUMEM_ENABLE`을
env allowlist(호스트→원격, 원격→컨테이너 양쪽)에 넣었습니다.
`mlperf_train_v51.sh`, `mlperf_train_v41.sh` 둘 다입니다.
이게 없으면 STEP 3의 변수가 컨테이너까지 못 갑니다.

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| llama31_8b 정밀도 | **`bf16`만 허용** — 수정 완료(`d4a11f3`), 이번 실행에서 통과 확인 |
| llama2_70b_lora 정밀도 | `trainer.precision`을 안 읽음. `bf16-mixed`여도 무해 |
| 크래시 지점 | **NCCL 초기화 직후**. 모델 커널 실행 전 |
| 크래시 재현 범위 | 벤치마크·이미지·노드 3개를 다 바꿔도 동일 |
| GPU compute capability | 10.3 (`sm_103`) |
| 호스트 IB | NIC 전부 ACTIVE / link up |
| `nvidia_peermem` | 로드됨 (컨테이너 배너의 "not detected"는 오탐) |
| 컨테이너 UCX | `mlx5_0`~`mlx5_15`, `cuda_cpy`, `cuda_ipc` 전부 정상 인식 |
| UCX transport | 원인 아님. 4프레임 백트레이스는 UCX의 전역 시그널 핸들러 |
| 런처 코드 | `mlperf_run.sh` / `common.sh` 원본과 동일 |
| 컨테이너 인자 | `--ipc=host`, `--ulimit memlock=-1`, `--network=host`, IB 패스스루 정상 |
| `-sm90` 이미지 | CUDA 13.0, PyTorch 2.9.0a0 (NGC 25.09), arch list에 `sm_103` 없음 |

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP(`node25`)와 호스트명(`node-26049`)이 그대로
들어가 있습니다. 이 저장소는 public입니다. 원하시면 익명화해 드리겠습니다.
