# Next Steps

- 갱신: 2026-08-26 (15회차)
- 상태: **IB 멀티노드 NCCL 통과.** 원인은 PCIe ACS였습니다
- 이번 목표: 멀티노드 학습

---

## 1. 해결된 것

| | |
|---|---|
| 원인 | **PCIe ACS**가 NIC↔GPU P2P DMA를 루트 컴플렉스로 우회시킴 |
| 증상 | IB 멀티노드에서만 `status=4` (`IBV_WC_LOC_PROT_ERR`) |
| 조치 | ACS 해제 |
| 확인 | GDR 켠 상태로 IB 멀티노드 프로브 통과 |

단일 노드·`ib_write_bw`·Socket이 전부 멀쩡했던 이유도 이걸로 설명됩니다.
셋 다 **NIC가 GPU 메모리에 직접 접근하지 않는** 경로였습니다.

---

## 2. 멀티노드 학습 전에 두 가지

### 2-1. ACS 영구화 — **지금 하세요**

`setpci`로 끄셨다면 **재부팅하면 원복됩니다.**
긴 벤치마크를 돌리다 노드가 재부팅되면 조용히 예전 증상으로 돌아갑니다.

```bash
# 현재 상태 재확인 (두 노드 다)
./scripts/acs_check.sh --host $N1
./scripts/acs_check.sh --host $N2
```

영구 조치는 둘 중 하나입니다.

1. **BIOS에서 ACS 해제** — 권장. 보통 "ACS Enable" 또는 IOMMU 항목 아래
2. **부팅 시 재적용하는 systemd 유닛** — BIOS 옵션이 없거나 재부팅 일정이 안 맞을 때

측정 결과를 남기기 전에 **어느 쪽인지 확정**해 두세요.
나중에 "그때는 됐는데" 가 되기 쉬운 종류의 설정입니다.

### 2-2. 로그 경로 — 고쳤습니다

**`git pull` 필요** (`14c29a1`).

로그 루트가 네 스크립트 모두 `/opt/poc-platform/...`로 박혀 있었습니다.
이제 `.env`에서 정합니다.

```
MLPERF_LOG_ROOT  >  POC_PLATFORM_ROOT  >  /opt/poc-platform
```

**`POC_PLATFORM_ROOT`를 이미 `/mgmt/server/poc-platform`으로 두셨다면
아무것도 안 하셔도 됩니다.** 로그가 알아서 따라갑니다.

```
/mgmt/server/poc-platform/mlperf_logs_train_v51/...
```

따로 지정하려면 `.env`에 한 줄이면 됩니다.

```bash
MLPERF_LOG_ROOT=/mgmt/server/poc-platform
```

각 suite가 자기 하위 디렉터리를 붙이므로(`mlperf_logs_train_v51`,
`mlperf_logs_infer_v60` …) 루트 하나만 주시면 됩니다.

> **멀티노드에서 중요합니다.** 로그는 컨테이너를 띄운 **각 노드**에 쓰입니다.
> 이 경로가 공유 스토리지면 한 실행의 로그가 한곳에 모입니다.
> 디렉터리 이름에 호스트명이 들어가므로 노드끼리 충돌하지 않습니다.

---

## 준비

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

N1=node19
N2=node20
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b-pyt-blackwell.tar
```

---

## STEP 1 — 데이터가 양쪽에 보이는지 (10초)

멀티노드는 모든 노드가 같은 경로로 데이터를 봐야 합니다.

```bash
for h in $N1 $N2; do
  echo "=== $h ==="
  ssh $h 'ls /mgmt/server/poc-platform/data/training_llama31_8b/8b 2>&1 | head -3'
  ssh $h "docker image inspect $IMG >/dev/null 2>&1 && echo '  image: OK' || echo '  image: MISSING'"
done
```

이미지가 없는 노드가 있으면 먼저 올려두세요.

```bash
ssh <노드> "docker load -i $TAR"
```

---

## STEP 2 — 멀티노드 학습 (2노드 16 GPU)

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_multi_node.sh --hosts $N1,$N2 \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --cp 1 --mbs 1 --gbs 256 --max-steps 10
```

**GBS가 256인 이유**

```
WORLD = 8 GPU x 2 node = 16
DP    = WORLD / (TP x PP x CP) = 16 / 8 = 2
GBS는 MBS(1) x DP(2) = 2 의 배수
GBS=256 -> grad_accum = 128
```

단일 노드(GBS=128, DP=1)와 **스텝당 샘플 수가 같아집니다.** 비교하려면 이 값이 맞습니다.

**로그에서 확인할 것**

```
[INFO] mode=multi nnodes=2 gpus_per_node=8 world_size_gpus=16
[INFO] parallel: TP=8 PP=1 CP=1 -> DP=2 (world=16)
[INFO] batch:    MBS=1 GBS=256 grad_accum=128
[INFO] rank0=... (MASTER_ADDR source)
[INFO] log_dir=/mgmt/server/...        <- 새 경로가 맞는지
[CONTAINER] B300: NCCL_NET_PLUGIN=none ...
++trainer.precision=bf16
```

런처가 자동으로 고른 RDMA 값도 같이 봐주세요. 프로브 때와 달라졌다면 그게 단서입니다.

```
NCCL_IB_HCA=...   NCCL_SOCKET_IFNAME=...
```

---

## STEP 3 — 단일 노드와 비교

멀티노드가 돌면 스케일링을 봅니다. **여기서 SHARP 부재가 처음 수치로 드러납니다.**

```bash
# 같은 조건 단일 노드 (비교 기준)
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $N1 \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

스텝 시간을 비교하세요. 2노드가 1노드보다 **크게 느리면** 노드 간 통신이 병목입니다.
그 경우 `NCCL_DEBUG=INFO`로 실제 경로가 IB인지(Socket으로 떨어지지 않았는지) 확인합니다.

---

## STEP 4 — 회신

1. STEP 2 — 스텝이 도는지, `log_dir`이 새 경로로 찍히는지
2. STEP 3 — 1노드 대비 2노드 스텝 시간
3. ACS를 BIOS로 영구화했는지 / systemd로 했는지

---

## 남은 이슈

| 항목 | 상태 |
|---|---|
| **SHARP 부재** | B300은 HPC-X 플러그인을 끄므로 in-network reduction 없음. 멀티노드 allreduce가 느립니다. 정식 측정 전에 이미지 교체 여부를 정해야 합니다 |
| `NCCL_IB_DISABLE=1` 무시됨 | 진단 중 발견. 지금 막히는 건 없지만 원인 미상 |
| llama2_70b_lora | 아직 B300에서 안 돌려봤습니다. 8b가 되면 그다음 |

---

## 이 건에서 고친 것들

| 커밋 | 내용 |
|---|---|
| `d4a11f3` | llama31_8b 정밀도 — `bf16-mixed` → `bf16` |
| `19cad5e` | TP=1일 때 sequence parallelism 자동 해제 |
| `76a7fc8` | `MLPERF_TRAIN_IMAGE_TAR`로 이미지에 맞는 tar 지정 |
| `489dc11` | **B300에서 `NCCL_NET_PLUGIN=none`** — SIGSEGV 원인 해결 |
| `a3d213a`, `2599300` | `nccl_probe.sh` — NCCL만 30초 검증, 단일/멀티 |
| `a4fa8b6` | `acs_check.sh` — **IB 실패 원인 규명** |
| `14c29a1` | 로그 루트를 `.env`에서 지정 가능하게 |

---

## 확정된 사실 (기록용)

| 항목 | 결과 |
|---|---|
| 단일 노드 학습 8장 | 통과 |
| 멀티노드 NCCL (IB, GDR 켬) | **통과 — ACS 해제 후** |
| IB 실패 원인 | **PCIe ACS**. `status=4` = local protection error |
| SIGSEGV 원인 | HPC-X `libnccl-net.so` ↔ NCCL 2.28.3 불일치 |
| 드라이버 | 580.173.02 (r580) — 정상 |
| `ib_write_bw` | 호스트 메모리 기준이라 GDR 검증이 아니었음 |
| 호스트 NCCL / HPC-X | 컨테이너와 무관 |
