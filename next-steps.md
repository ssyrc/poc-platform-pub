# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (4회차)
- 대상 증상: training v5.1 단일노드 SIGSEGV (B300)

---

## 이번 회차의 핵심 발견

### 1. 이미지에 `sm_103`이 없습니다

```
['sm_75', 'sm_80', 'sm_86', 'sm_90', 'sm_100', 'sm_120', 'compute_120']
```

**B300(Blackwell Ultra)은 compute capability 10.3 = `sm_103`입니다.**
목록에 `sm_100`과 `sm_120`은 있는데 **`sm_103`은 없습니다.**

`compute_120` PTX가 있지만 JIT은 위로만 가능해서 12.0 PTX가 10.3으로 내려오지 못합니다.
즉 이 이미지에는 B300용 네이티브 커널도, 폴백 경로도 없을 가능성이 큽니다.

그리고 `NVTE_CUDA_ARCHS=`가 **비어 있습니다.** 발행자 문서는 `-sm90` 태그가
`89;90;100a;103a`로 빌드됐다고 했는데, 컨테이너에서 확인이 안 됩니다.

### 2. 항상 **rank 6**에서 죽습니다

```
failed (exitcode: -11) local_rank: 6 (pid: 320) of binary: /usr/bin/python
traceback : Signal 11 (SIGSEGV) received by PID 320
```

나머지 랭크는 SIGTERM으로 정리된 것뿐이고, **실제로 죽은 건 rank 6 하나**입니다.
1회차 로그에서도 pid 320이었습니다 — **두 번 다 같은 랭크**입니다.

특정 랭크에서만 반복해서 죽는 건 아키텍처 미지원보다 **특정 GPU 문제**에 가까운 패턴입니다.
두 가설이 공존하므로 아래 STEP 1·2로 갈라냅니다.

---

## 준비

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull                      # PYTHONFAULTHANDLER 전달 (커밋 e72de4d)

NODE=<대상 노드 IP>
IMAGE=donnmyth/mlperf-nvidia:llama2_70b_lora-pyt-sm90
```

---

## STEP 1 — GPU의 실제 compute capability 확인  ← 1순위, 1줄

`sm_103` 가설을 확정하거나 폐기합니다.

```bash
ssh $NODE 'nvidia-smi --query-gpu=index,name,compute_cap --format=csv'
```

| 결과 | 의미 |
|---|---|
| `10.3` | 이미지의 `sm_103` 부재가 유력한 원인 → STEP 3 |
| `10.0` | 이미지에 `sm_100`이 있으므로 아키텍처는 무관 → STEP 2 |

---

## STEP 2 — rank 6 / GPU 6 격리  ← 1순위, 결정적

GPU 6을 빼고 4장으로만 돌립니다. 통과하면 원인이 특정 GPU로 좁혀집니다.

```bash
UCX_HANDLE_ERRORS=none PYTHONFAULTHANDLER=1 TORCH_SHOW_CPP_STACKTRACES=1 \
./scripts/run_single_node.sh --host $NODE --gpus 4 --tp 4 --pp 1 --mbs 1 --gbs 64 --max-steps 10
```

| 결과 | 의미 |
|---|---|
| **통과** | GPU 4~7 중 문제 있음 → 아래로 범위 좁히기 |
| rank 2 등 **다른 랭크**에서 죽음 | 특정 GPU 문제 아님 → 아키텍처 쪽 (STEP 3) |
| 여전히 죽음 | GPU 0~3에도 재현 → 아키텍처 쪽 (STEP 3) |

통과했다면 반대쪽 4장으로 확인합니다.

```bash
MLPERF_CUDA_VISIBLE_DEVICES=4,5,6,7 \
UCX_HANDLE_ERRORS=none PYTHONFAULTHANDLER=1 \
./scripts/run_single_node.sh --host $NODE --gpus 4 --tp 4 --pp 1 --mbs 1 --gbs 64 --max-steps 10
```

GPU 6 상태도 함께 봅니다.

```bash
ssh $NODE 'nvidia-smi -i 6 -q | grep -iE "ecc|retired|remapp|pending|xid"'
ssh $NODE 'dmesg | grep -iE "xid|nvrm" | tail -20'
```

**Xid 에러가 보이면 하드웨어/드라이버 문제로 확정**입니다.

---

## STEP 3 — Blackwell 전용 태그로 A/B

STEP 1이 `10.3`이거나 STEP 2에서 특정 GPU가 아니라고 나오면 이미지를 바꿔 봅니다.

```bash
UCX_HANDLE_ERRORS=none PYTHONFAULTHANDLER=1 TORCH_SHOW_CPP_STACKTRACES=1 \
./scripts/run_single_node.sh --host $NODE \
  --docker-image donnmyth/mlperf-nvidia:llama2_70b_lora-pyt \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

먼저 그 이미지의 커버리지부터 봐도 좋습니다.

```bash
ssh $NODE "docker run --rm --gpus all donnmyth/mlperf-nvidia:llama2_70b_lora-pyt \
  python -c 'import torch; print(torch.cuda.get_arch_list())'"
```

여기에 `sm_103`이 있고 실행도 통과하면 **B300은 이 태그를 써야 한다**가 확정됩니다.
그러면 런처 기본값을 그렇게 바꾸겠습니다. 실측이 발행자 문서를 이깁니다.

---

## STEP 4 — TransformerEngine 커널 실측 (보조)

PyTorch가 아니라 TE 쪽에 sm_103이 있는지 봅니다.

```bash
ssh $NODE "docker run --rm --gpus all $IMAGE bash -c '
so=\$(find / -name \"*.so\" -path \"*transformer_engine*\" 2>/dev/null | head -1)
echo \"== \$so\"
cuobjdump --list-elf \"\$so\" 2>/dev/null | grep -oE \"sm_[0-9]+\" | sort -u | tr \"\\n\" \" \"'"
```

---

## STEP 5 — 결과 회신

`Errors`에 다음을 붙여주세요.

1. **STEP 1의 `compute_cap`** (한 줄이지만 가장 결정적)
2. **STEP 2의 결과** — 통과 여부, 죽었다면 어느 rank인지
3. `nvidia-smi -i 6 -q`의 ECC/retired/remapped, `dmesg`의 Xid
4. STEP 3을 했다면 그 arch list와 실행 결과

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| 호스트 IB | NIC 전부 ACTIVE / link up |
| `nvidia_peermem` | 로드됨 (컨테이너 배너의 "not detected"는 오탐) |
| 컨테이너 UCX | `mlx5_0`~`mlx5_15`, `cuda_cpy`, `cuda_ipc` 전부 정상 인식 |
| UCX transport | 원인 아님. 4프레임 백트레이스는 UCX의 전역 시그널 핸들러였음 |
| 런처 코드 | `mlperf_run.sh` / `common.sh` 원본과 동일. v5.1은 tar 폴백과 env 목록만 추가 |
| 컨테이너 인자 | `--ipc=host`, `--ulimit memlock=-1`, `--network=host`, IB 패스스루 모두 정상 |
| 이미지 CUDA | 13.0, PyTorch 2.9.0a0 (NGC 25.09) |

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP와 호스트명이 그대로 들어가 있습니다. 이 저장소는 public이므로
익명화하거나 파일을 지우는 편이 좋습니다. 원하시면 정리해 드리겠습니다.
