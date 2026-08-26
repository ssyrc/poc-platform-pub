# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-27 (5회차)
- 이번 목표: Blackwell 빌드 이미지로 `llama31_8b` 테스트

---

## 확정된 사실

**B300 = compute capability 10.3 = `sm_103`** (`nvidia-smi --query-gpu=compute_cap`로 확인)

현재 쓰던 `-sm90` 이미지의 arch list에는 `sm_103`이 없습니다.

```
['sm_75', 'sm_80', 'sm_86', 'sm_90', 'sm_100', 'sm_120', 'compute_120']
```

`sm_100`은 있지만 일반 cubin의 minor 상위 호환이 통하는지와 별개로,
TransformerEngine이 쓰는 `sm_100a` 같은 **architecture-specific 타겟은 상위 호환이 없습니다.**
`103a`가 빠져 있으면 B300에서 TE 커널이 없습니다.

→ `llama31_8b-pyt-blackwell` tar를 `dockerimgs`에 배치 완료. 이걸로 테스트합니다.

---

## 새로 가능해진 것 (커밋 `76a7fc8`)

`--docker-image`로 이미지를 바꿔도 **tar 경로는 기본 이미지 것 그대로**였습니다.
폐쇄망에서는 엉뚱한 tar를 로드하고 → 요청한 태그는 여전히 없고 → `docker pull`로 넘어가 실패합니다.

`MLPERF_TRAIN_IMAGE_TAR`로 짝이 맞는 tar를 지정할 수 있게 했습니다.
(inference의 `MLPERF_INFER_IMAGE_TAR`와 같은 방식)

---

## 준비

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

NODE=<대상 노드 IP>
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b_pyt-blackwell.tar
```

---

## STEP 1 — tar 로드하고 실제 태그 확인

tar 안의 태그가 예상과 다를 수 있으므로 **출력된 이름을 그대로** 다음 단계에 씁니다.

```bash
ssh $NODE "docker load -i $TAR"
ssh $NODE 'docker images | grep -i llama31_8b'
```

확인된 태그를 변수에 넣습니다.

```bash
IMG=<위에서 확인한 REPOSITORY:TAG>
```

---

## STEP 2 — 이 이미지가 `sm_103`을 담고 있는지 확인

이번 시도의 전제입니다. 한 줄로 끝납니다.

```bash
ssh $NODE "docker run --rm --gpus all $IMG \
  python -c 'import torch; print(torch.cuda.get_arch_list())'"
```

TransformerEngine 쪽도 함께 봅니다. **여기에 `sm_103` 또는 `sm_103a`가 있어야** B300에서
FP8 커널이 돕니다.

```bash
ssh $NODE "docker run --rm --gpus all $IMG bash -c '
so=\$(find / -name \"*.so\" -path \"*transformer_engine*\" 2>/dev/null | head -1)
echo \"== \$so\"
cuobjdump --list-elf \"\$so\" 2>/dev/null | grep -oE \"sm_[0-9]+[a-z]*\" | sort -u | tr \"\\n\" \" \"'"
```

---

## STEP 3 — `llama31_8b` 실행

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

**전달 확인용으로 로그에서 볼 것**

- `[INFO] fallback_tar=...llama31_8b_pyt-blackwell.tar` — tar override가 걸렸는지
- `[INFO] docker_image=...` — 의도한 태그인지
- `[INFO] advanced env forwarded:` 에 `UCX_HANDLE_ERRORS`, `PYTHONFAULTHANDLER`

데이터가 없다면 먼저 확인하세요.

```bash
./scripts/preflight.sh training v5.1
```

`llama31_8b` 데이터셋은 `${MLPERF_DATA_ROOT}/training_llama31_8b/8b` 입니다.

---

## STEP 4 — GPU 6 격리 (병행 권장, 2~3분)

**두 번 다 `rank 6`에서만 죽었습니다.** 나머지 랭크는 torchrun이 SIGTERM으로 정리한 것뿐입니다.
아키텍처 문제라면 모든 랭크가 같이 죽어야 하므로, 이 패턴은 특정 GPU를 가리킵니다.

STEP 3과 독립이므로 언제 돌려도 됩니다. **현재 구성 그대로 GPU 0~3만** 사용합니다.

```bash
UCX_HANDLE_ERRORS=none PYTHONFAULTHANDLER=1 \
./scripts/run_single_node.sh --host $NODE --gpus 4 --tp 4 --pp 1 --mbs 1 --gbs 64 --max-steps 10
```

| 결과 | 의미 |
|---|---|
| 통과 | GPU 4~7 쪽 문제. 이미지를 바꿔도 8장 쓰면 재발합니다 |
| 다른 랭크에서 죽음 | 특정 GPU 아님. 아키텍처 가설이 유력해집니다 |

하드웨어 증거도 같이 봅니다. **Xid가 보이면 하드웨어로 확정**입니다.

```bash
ssh $NODE 'nvidia-smi -i 6 -q | grep -iE "ecc|retired|remapp|pending"'
ssh $NODE 'dmesg | grep -iE "xid|nvrm" | tail -20'
```

---

## STEP 5 — 결과 회신

`Errors`에 붙여주세요.

1. STEP 1의 `docker images` 출력 (실제 태그)
2. STEP 2의 `get_arch_list()`와 TE의 `sm_*` 목록
3. STEP 3 결과 — 통과했는지, 죽었다면 **어느 rank**인지와 Python traceback
4. STEP 4를 했다면 그 결과

STEP 3이 통과하면 **B300은 blackwell 태그를 써야 한다**가 확정되고,
런처 기본값을 그렇게 되돌리겠습니다. (문서 근거로 `-sm90`으로 되돌린 이력이 있는데,
실측이 문서를 이깁니다.)

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| GPU compute capability | **10.3 (sm_103)** |
| 호스트 IB | NIC 전부 ACTIVE / link up |
| `nvidia_peermem` | 로드됨 (컨테이너 배너의 "not detected"는 오탐) |
| 컨테이너 UCX | `mlx5_0`~`mlx5_15`, `cuda_cpy`, `cuda_ipc` 전부 정상 인식 |
| UCX transport | 원인 아님. 4프레임 백트레이스는 UCX의 전역 시그널 핸들러였음 |
| 크래시 실체 | `local_rank 6` 프로세스의 SIGSEGV (`exitcode -11`), 2회 모두 동일 |
| 런처 코드 | `mlperf_run.sh` / `common.sh` 원본과 동일 |
| 컨테이너 인자 | `--ipc=host`, `--ulimit memlock=-1`, `--network=host`, IB 패스스루 모두 정상 |
| 기존 이미지 | CUDA 13.0, PyTorch 2.9.0a0 (NGC 25.09), arch list에 `sm_103` 없음 |

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP와 호스트명이 그대로 들어가 있습니다. 이 저장소는 public이므로
익명화하거나 파일을 지우는 편이 좋습니다. 원하시면 정리해 드리겠습니다.
