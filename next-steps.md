# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (6회차)
- 이번 결론: **SIGSEGV는 사라졌습니다.** 남은 건 정밀도 값 하나였고, 코드에서 고쳤습니다.

---

## 1. 무엇이 바뀌었나

이번 로그에는 SIGSEGV도, `rank 6`도, UCX 백트레이스도 없습니다.
대신 깨끗한 Python 예외 하나로 끝났습니다.

```
AssertionError: Unsupported precision bf16-mixed
  pretrain.py line 291, in get_model_with_precision
```

즉 **모델이 만들어지기 전에** 설정 검증에서 멈춘 것이고, 아키텍처·드라이버·IB·UCX와는
무관한 실패입니다.

**단, 이번 실행은 변수가 두 개 동시에 바뀌었습니다.**

| | 이전 (SIGSEGV) | 이번 |
|---|---|---|
| 이미지 | `-sm90` | `llama31_8b_pyt-blackwell` |
| 노드 | `...19` | `...25` |
| 벤치마크 | `llama2_70b_lora` | `llama31_8b` |

그래서 "blackwell 이미지가 SIGSEGV를 고쳤다"는 **아직 확정이 아닙니다.**
정밀도 문제를 넘긴 뒤 실제로 스텝이 도는 걸 봐야 확정됩니다. (아래 STEP 2)

---

## 2. 원인 — 확정 (업스트림 소스 확인)

`mlcommons/training_results_v5.1`의 `llama31_8b/implementations/nemo/pretrain.py`,
`get_model_with_precision` 끝부분입니다.

```python
if config.model.fp8 or config.model.fp4:      # FP8/FP4가 우선
    precision = MegatronMixedPrecision(precision="bf16-mixed", ...)
elif config.trainer.precision == "bf16":
    precision = MegatronMixedPrecision(precision="bf16-mixed", ...)
else:
    assert False, f"Unsupported precision {config.trainer.precision}"
```

**`trainer.precision`으로 받아주는 값은 `bf16` 하나뿐입니다.**
`bf16-mixed`는 내부에서 쓰는 값이지, 밖에서 넣는 값이 아닙니다.

같은 파일 `get_optimizer`도 동일합니다.

```python
bf16 = config.trainer.precision == "bf16"
```

`bf16-mixed`를 넣으면 여기서도 False가 되어 옵티마이저 경로까지 어긋납니다.

### 왜 llama2_70b_lora는 멀쩡했나

`llama2_70b_lora/implementations/nemo/train.py`는 이 키를 **읽지 않습니다.**
자기가 직접 `nl.MegatronMixedPrecision(precision="bf16-mixed")`로 박아 씁니다.
그래서 같은 `bf16-mixed`를 넘겨도 무해했고, 이번에 8b로 옮기면서 처음 드러난 것입니다.

### FP8은 이 키로 켜는 게 아닙니다

8b에서 FP8/FP4는 `model.fp8`로 분기하고 `trainer.precision`은 `bf16`으로 둡니다.
기존 스크립트는 FP8일 때 `transformer-engine`을 넣고 있었는데, 이것도 같은 이유로
틀린 값이었습니다. 함께 고쳤습니다.

---

## 3. 적용한 수정

`scripts/mlperf_train_v51.sh`의 **llama31_8b 분기에 한해** 정밀도 매핑을 바꿨습니다.
(`llama2_70b_lora` 분기와 `mlperf_train_v41.sh`는 손대지 않았습니다. v4.1에는 8b가 없습니다.)

| 입력 | 이전 → 결과 | 지금 → 결과 |
|---|---|---|
| (미지정) | `bf16-mixed` → **abort** | `bf16` → 정상 |
| `BF16-mixed` / `bf16-mixed` | `bf16-mixed` → **abort** | `bf16` → 정상 |
| `BF16` | `bf16` → 정상 | `bf16` → 정상 |
| `FP8` | `transformer-engine` → **abort** | `bf16` + `model.fp8=True` |
| `FP8_HYBRID` | `transformer-engine` → **abort** | `bf16` + `model.fp8_hybrid=True` |
| 그 외 (FP16/FP32 등) | 제각각 | 경고 후 `bf16` |

---

## 4. 준비

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

NODE=node25
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b_pyt-blackwell.tar
IMG=<STEP 1에서 확인한 REPOSITORY:TAG>
```

---

## STEP 1 — 다시 실행 (수정된 코드로)

정밀도 관련 플래그는 **주지 마세요.** 기본값이 이제 `bf16`입니다.

```bash
UCX_HANDLE_ERRORS=none \
PYTHONFAULTHANDLER=1 \
TORCH_SHOW_CPP_STACKTRACES=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama31_8b \
  --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

**로그에서 확인할 것**

```
++trainer.precision=bf16        <- -mixed 가 붙어 있으면 pull이 안 된 것입니다
```

`[CONTAINER] FP8=False FP8_HYBRID=False TRAINER_PRECISION=bf16` 줄도 같이 보입니다.

---

## STEP 2 — 결과에 따라

| 결과 | 의미 | 다음 |
|---|---|---|
| 스텝이 돈다 | **B300 + blackwell 이미지 확정.** SIGSEGV는 `-sm90`의 `sm_103` 부재였음 | 런처 기본 이미지를 blackwell로 되돌리겠습니다 |
| 또 SIGSEGV | 이미지 문제가 아니었음 | STEP 3(노드/GPU 격리)으로 갑니다 |
| 다른 Python 예외 | 설정이 하나 더 남은 것 | 그 traceback을 `Errors`에 주세요. 위처럼 소스에서 확정하겠습니다 |

---

## STEP 3 — SIGSEGV가 재현될 때만

이전 SIGSEGV는 **두 번 다 `rank 6`에서만** 났고, 그건 아직 설명되지 않은 채입니다.
이번에 재현되면 그때 돌리세요. 안 나면 건너뛰어도 됩니다.

```bash
# GPU 0~3만
UCX_HANDLE_ERRORS=none PYTHONFAULTHANDLER=1 MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE --benchmark llama31_8b --docker-image $IMG \
  --gpus 4 --tp 4 --pp 1 --mbs 1 --gbs 64 --max-steps 10

# 하드웨어 증거 (Xid가 보이면 하드웨어 확정)
ssh $NODE 'nvidia-smi -i 6 -q | grep -iE "ecc|retired|remapp|pending"'
ssh $NODE 'dmesg | grep -iE "xid|nvrm" | tail -20'
```

**참고:** 이전 SIGSEGV는 `...19`, 이번 실행은 `...25`입니다. 같은 노드에서 비교해야
의미가 있습니다.

---

## STEP 4 — 회신

`Errors`에 붙여주세요.

1. `++trainer.precision=` 이 실제로 무엇으로 찍혔는지
2. 통과했다면 몇 스텝까지 돌았는지 / 실패했다면 rank와 traceback
3. STEP 1의 `docker images` 태그 (아직 안 주셨습니다)
4. 이미지의 `torch.cuda.get_arch_list()` 결과 — `sm_103` 유무

3, 4번은 blackwell 이미지 가설을 문서로 굳히는 데 필요합니다.

```bash
ssh $NODE 'docker images | grep -i llama31_8b'
ssh $NODE "docker run --rm --gpus all $IMG python -c 'import torch; print(torch.cuda.get_arch_list())'"
```

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| llama31_8b 정밀도 | **`bf16`만 허용** (업스트림 `pretrain.py:291`에서 확정) |
| llama2_70b_lora 정밀도 | `trainer.precision`을 안 읽음. `bf16-mixed`여도 무해 |
| GPU compute capability | **10.3 (sm_103)** |
| 호스트 IB | NIC 전부 ACTIVE / link up |
| `nvidia_peermem` | 로드됨 (컨테이너 배너의 "not detected"는 오탐) |
| 컨테이너 UCX | `mlx5_0`~`mlx5_15`, `cuda_cpy`, `cuda_ipc` 전부 정상 인식 |
| UCX transport | 원인 아님. 4프레임 백트레이스는 UCX의 전역 시그널 핸들러였음 |
| 런처 코드 | `mlperf_run.sh` / `common.sh` 원본과 동일 |
| 컨테이너 인자 | `--ipc=host`, `--ulimit memlock=-1`, `--network=host`, IB 패스스루 모두 정상 |
| `-sm90` 이미지 | CUDA 13.0, PyTorch 2.9.0a0 (NGC 25.09), arch list에 `sm_103` 없음 |

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP와 호스트명이 그대로 들어가 있습니다. 이 저장소는 public이므로
익명화하거나 파일을 지우는 편이 좋습니다. 원하시면 정리해 드리겠습니다.
