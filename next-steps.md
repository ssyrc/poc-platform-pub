# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (8회차)
- 이번 결론: **이미지 가설은 끝났습니다.** 1-GPU 테스트는 아직 유효한 답을 못 냈습니다.

---

## 1. blackwell 이미지 = sm90 이미지 (같은 빌드입니다)

```
['sm_75', 'sm_80', 'sm_86', 'sm_90', 'sm_100', 'sm_120', 'compute_120']
NVIDIA Release 25.09 / PyTorch 2.9.0a0+50eac81
```

**`-sm90` 이미지에서 나온 것과 글자 하나까지 같습니다.** 빌드 해시까지 동일합니다.
태그만 `-blackwell`이지 내용물이 다른 이미지가 아닙니다.

그래서 지난 라운드에 제가 세운 "blackwell 이미지로 바꾸면 될 것" 가설은 **틀렸습니다.**
이미지를 바꾼 게 아니라 같은 이미지를 다시 받은 셈이고, 그래서 SIGSEGV도 그대로 났습니다.

### 그리고 `sm_103`은 애초에 문제가 아니었습니다

CUDA cubin은 **같은 major 아키텍처 안에서 minor 상위 호환**입니다.
`sm_100` cubin은 compute capability 10.3 장비에서 그대로 돕니다. 재컴파일 필요 없습니다.

즉 위 arch list는 B300에서 **정상**입니다. torch 커널은 문제가 없습니다.

예외는 하나뿐입니다 — `sm_100a`처럼 **architecture-specific(`a` 접미사)** 타겟.
이건 상위 호환이 없습니다. TransformerEngine이 이걸 씁니다.
그래서 남은 arch 관련 확인은 아래 STEP 4 하나이고, 그것도 우선순위가 낮습니다.
(크래시가 TE 커널이 돌기 한참 전에 나기 때문입니다.)

---

## 2. 1-GPU 테스트는 무효입니다 — 크래시 지점에 닿지도 못했습니다

```
ValueError: Can not use sequence paralllelism without tensor parallelism
  model_parallel_config.py:359
```

`trainer.fit` → `strategy.connect(model)` 에서 났습니다. **NCCL 초기화 전**입니다.
SIGSEGV가 나는 자리보다 한참 앞이라 "1장은 되더라"도 "1장도 안 되더라"도 아닙니다.

원인은 제 스크립트 쪽이었습니다. 8b 기본 설정이 `model.sequence_parallel`을 켜두는데,
sequence parallelism은 tensor-parallel 그룹을 쪼개 쓰는 기능이라 그룹이 1랭크면
Megatron이 거부합니다. TP=1을 주면 무조건 이 에러가 납니다.

**고쳤습니다.** PP=1일 때 interleaved pipeline을 자동으로 끄던 것과 같은 방식으로,
TP=1이면 `++model.sequence_parallel=False`를 자동으로 붙입니다.
로그에 이 줄이 보이면 적용된 것입니다.

```
[CONTAINER] TP=1 detected; disabling sequence parallelism
```

---

## 3. 지금까지 남은 그림

| | 1차 | 2차 | 3차 |
|---|---|---|---|
| 벤치마크 | llama2_70b_lora | llama2_70b_lora | llama31_8b |
| 이미지 | `-sm90` | `-sm90` | `-blackwell` = **같은 빌드** |
| 노드 | `-26043` | `-26043` | `-26049` |
| 죽은 자리 | NCCL 초기화 직후 | NCCL 초기화 직후 | NCCL 초기화 직후 |

벤치마크가 달라도, 노드가 달라도 같은 자리입니다.
이미지는 애초에 안 바뀌었으니 변수에서 빼야 합니다.

**남은 후보는 두 개입니다.**

1. 8-GPU 통신 계층 (NVLink / NVSwitch / P2P / NCCL 2.28)
2. 노드 공통 설정 — 특히 **NVSwitch fabric**

2번은 아직 한 번도 확인 안 했습니다. B300은 NVSwitch 노드라 이게 핵심입니다.

---

## 준비

`git pull`은 **제가 코드를 고쳤다고 적은 라운드에만** 하시면 됩니다.
필요한 STEP에는 커밋 번호와 함께 표시해 두겠습니다. 표시가 없으면 안 하셔도 됩니다.


```bash
cd /mgmt/server/poc-platform/poc-platform-pub

NODE=node25
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b_pyt-blackwell.tar
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
```

---

## STEP 1 — NVSwitch fabric 확인 (30초, 지금 제일 중요)

`git pull` 불필요 — ssh만 씁니다.

**NVSwitch 노드에서 fabricmanager가 안 떠 있으면 GPU 간 P2P가 깨진 채로 초기화가
진행되다 죽습니다. 증상이 정확히 지금 자리입니다.**

```bash
ssh $NODE 'systemctl is-active nvidia-fabricmanager; systemctl is-active nvidia-imex'
ssh $NODE 'nvidia-smi -q | grep -iA6 "fabric"'
ssh $NODE 'dmesg | grep -iE "xid|nvrm|nvswitch|imex" | tail -30'
```

**볼 것**

| 출력 | 판정 |
|---|---|
| `fabricmanager: inactive` | **여기가 원인입니다.** 기동 후 재시도 |
| fabric `State: Completed` + `Status: Success` | 정상. STEP 2로 |
| fabric `State`가 그 외 | 비정상. 그 값을 주세요 |

---

## STEP 2 — 1-GPU 다시

**`git pull` 필요** (`19cad5e` — TP=1 sequence parallelism 자동 해제).
이거 없이 돌리면 지난번과 똑같은 `ValueError`가 납니다.

이제 sequence parallelism 때문에 죽지 않습니다. **NCCL도 NVLink도 P2P도 안 씁니다.**

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
TORCH_SHOW_CPP_STACKTRACES=1 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama31_8b --docker-image $IMG \
  --gpus 1 --tp 1 --pp 1 --mbs 1 --gbs 8 --max-steps 5
```

| 결과 | 결론 |
|---|---|
| **스텝이 돈다** | 통신 계층 확정. 소프트웨어 스택은 멀쩡함 → STEP 3 |
| **signal 11** | 통신 무관. 드라이버/라이브러리 문제 → STEP 4 |
| 또 다른 설정 에러 | 그 traceback 주세요. 소스에서 확정하겠습니다 |

---

## STEP 3 — NCCL 경로 하나씩 끄기 (STEP 2가 통과했을 때)

**`git pull` 필요** (`cd1e79e` — `NCCL_*` 변수 forward).
이거 없이 걸면 변수가 컨테이너까지 못 가서 아무 효과가 없습니다.
STEP 2를 위해 이미 pull 하셨다면 그대로 됩니다.

```bash
# (a) P2P(NVLink 직결) 끄고 8장
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= NCCL_DEBUG=INFO \
NCCL_P2P_DISABLE=1 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 5

# (b) NVLS(NVSwitch multicast) 끄고 8장 — Blackwell + NCCL 2.28에서 흔한 지점
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= NCCL_DEBUG=INFO \
NCCL_NVLS_ENABLE=0 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 5
```

(b)는 STEP 1에서 fabric이 정상으로 나왔을 때 특히 유력합니다.
NVLS는 NVSwitch multicast를 쓰는데, fabric이 반쯤 올라온 상태면 여기서 터집니다.

`NCCL_DEBUG=INFO` 로그를 꼭 같이 주세요. NCCL이 어디까지 갔는지 나옵니다.

---

## STEP 4 — TE의 arch 타겟 (우선순위 낮음)

`git pull` 불필요 — ssh만 씁니다.

위에서 적었듯 `sm_100` cubin은 B300에서 정상 동작합니다.
남은 건 TransformerEngine의 `a` 접미사 타겟뿐이고, 크래시는 TE가 돌기 전에 납니다.
**STEP 2가 signal 11로 끝났을 때만** 보세요.

```bash
ssh $NODE "docker run --rm --gpus all $IMG bash -c '
so=\$(find / -name \"*.so\" -path \"*transformer_engine*\" 2>/dev/null | head -1)
echo \"== \$so\"
cuobjdump --list-elf \"\$so\" 2>/dev/null | grep -oE \"sm_[0-9]+[a-z]*\" | sort -u | tr \"\\n\" \" \"'"
```

`sm_100a`만 있고 `sm_103a`가 없으면 그건 그거대로 나중에 문제가 됩니다.
다만 지금 크래시의 원인은 아닙니다.

---

## STEP 5 — 아직 못 받은 것

8-GPU SIGSEGV 로그가 UCX 백트레이스 4줄에서 잘려 있습니다.
그 뒤 torchrun이 찍는 블록이 **어느 rank가 죽었는지** 알려줍니다.

```
Root Cause (first observed failure):
  [0]: ... local_rank: N (pid: ...) ... exitcode: -11
```

이게 있어야 `rank 6` 가설을 접거나 되살릴 수 있습니다.
(1-GPU 실행에선 `local_rank: 0`까지 잘 나왔으니, 8-GPU 로그에도 분명히 있습니다.)

---

## STEP 6 — 회신

`Errors`에 붙여주세요.

1. STEP 1 — fabricmanager / fabric State (**제일 중요**)
2. STEP 2 — 1-GPU가 도는지
3. STEP 3 — 했다면 어느 쪽이 통과했는지 + `NCCL_DEBUG=INFO` 로그
4. STEP 5 — torchrun `Root Cause` 블록

---

## 이번에 코드에 고친 것

`scripts/mlperf_train_v51.sh` — TP=1이면 `++model.sequence_parallel=False`를 자동으로
붙입니다. PP=1일 때 virtual pipeline을 끄던 것과 같은 자리, 같은 방식입니다.
`--extra-overrides`는 그 뒤에 붙으므로 원하면 여전히 덮어쓸 수 있습니다.

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| blackwell 이미지 | **`-sm90`과 동일 빌드.** arch list·버전·빌드 해시 전부 같음 |
| `sm_103` | **문제 아님.** `sm_100` cubin이 minor 상위 호환으로 10.3에서 동작 |
| llama31_8b 정밀도 | `bf16`만 허용 — 수정 완료(`d4a11f3`), 통과 확인 |
| llama31_8b TP=1 | sequence parallelism 자동 해제 필요 — 수정 완료 |
| llama2_70b_lora 정밀도 | `trainer.precision`을 안 읽음. `bf16-mixed`여도 무해 |
| 크래시 지점 | NCCL 초기화 직후. 모델 커널 실행 전 |
| 크래시 재현 범위 | 벤치마크·노드를 바꿔도 동일 (이미지는 안 바뀌었음) |
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
