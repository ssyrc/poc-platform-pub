# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.

- 갱신: 2026-08-26 (14회차)
- 상태: **멀티노드 NCCL은 Socket으로 성공.** IB/RDMA 경로만 실패
- 이번 목표: IB를 살리는 것 (Socket은 느려서 벤치마크용으로 못 씁니다)

---

## 1. 직접 찾아내신 것 정리

| 시도 | 결과 |
|---|---|
| IB 기본 | `NET/IB ... status=4 vendor err 81` |
| `NCCL_IB_DISABLE=1` | 여전히 `net_ib.cc` 에러 (아래 참고) |
| `NCCL_NET=Socket` | IPv6 link-local(`fe80::...%bond0`)로 붙으려다 timeout |
| `NCCL_SOCKET_IFNAME='=bond0.3061'` + `NCCL_SOCKET_FAMILY=AF_INET` | **성공. 16 GPU all-reduce 통과** |

Socket 쪽 진단은 정확합니다. NCCL이 `bond0`의 IPv6 link-local을 골랐고,
`=`로 정확 매칭 + `AF_INET` 강제가 맞는 처방이었습니다.

**그 변수들을 스크립트에 반영했습니다.** 직접 고치신 `NCCL_SOCKET_FAMILY`를 포함해
`nccl_probe.sh`와 학습 스크립트 양쪽 allowlist에 넣었습니다. 이제 로컬 수정 없이 됩니다.

---

## 2. IB 실패의 정체 — GDR 의심이 맞습니다

```
NET/IB: Got completion from peer node20<57713> with status=4 opcode=0 len=0 vendor err 81 (Send) hca mlx5_0
```

**`status=4`는 IB verbs의 `IBV_WC_LOC_PROT_ERR` — local protection error입니다.**

이건 네트워크가 안 닿는다는 뜻이 **아닙니다.** 링크는 붙었고, QP도 맺어졌고,
completion까지 돌아왔습니다. 그런데 **로컬 메모리 영역에 HCA가 접근할 권한이 없다**는
겁니다. 즉 등록(registration)된 메모리 키가 실제로는 못 쓰는 상태입니다.

NCCL이 IB로 보내는 버퍼는 **GPU 메모리**입니다. 그 GPU 메모리를 HCA에 등록하는 게
GPUDirect RDMA이고, 그 등록이 겉으로만 성공하고 실제 접근이 막히면 정확히 이 에러가 납니다.

### `ib_write_bw`가 되는 것과 모순되지 않습니다

**`ib_write_bw`는 기본적으로 호스트 메모리를 씁니다.** GPU 메모리가 아닙니다.
그래서 그 테스트는 **파이버·스위치·QP는 정상**임을 증명하지만
**GDR에 대해서는 아무것도 말해주지 않습니다.** 지금 깨진 건 딱 그 부분입니다.

### 등록 경로가 둘입니다

이전 로그에 이 줄이 있었습니다.

```
NCCL INFO DMA-BUF is available on GPU device 0
```

NCCL은 GPU 메모리 등록에 **dma-buf**를 우선 씁니다. `nvidia_peermem`은 그 다음 후보입니다.
드라이버/MOFED 조합에 따라 **dma-buf 등록이 성공한 척하고 실제 접근에서 깨지는** 경우가
있고, 증상이 정확히 `status=4`입니다.

---

## 준비

**`git pull` 필요** (`아래 커밋` — `NCCL_DMABUF_ENABLE`, `NCCL_NET_GDR_LEVEL`,
`NCCL_SOCKET_FAMILY` 등 forward 추가).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

N1=node19
N2=node20
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell

# 매번 붙일 공통 부분
COMMON="NCCL_NET_PLUGIN=none NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1"
```

---

## STEP 1 — dma-buf 끄고 IB (30초, 제일 먼저)

**가장 좋은 결과가 나올 수 있는 시도입니다.** GDR은 그대로 두고 등록 경로만 바꿉니다.

```bash
env $COMMON NCCL_DMABUF_ENABLE=0 \
./scripts/nccl_probe.sh --hosts $N1,$N2 --image $IMG
```

| 결과 | 의미 |
|---|---|
| **통과** | dma-buf 등록이 범인. **GDR은 살아있고 성능 손실 없음** — 최선의 결과 |
| status=4 계속 | 등록 방식 문제가 아님 → STEP 2 |

이게 통과하려면 `nvidia_peermem`이 **양쪽 노드에** 올라와 있어야 합니다. STEP 3 먼저 보셔도 됩니다.

---

## STEP 2 — GDR 자체를 끄고 IB (30초, 판별용)

GPU 메모리를 직접 안 보내고 **호스트 메모리를 경유**합니다.

```bash
env $COMMON NCCL_NET_GDR_LEVEL=0 \
./scripts/nccl_probe.sh --hosts $N1,$N2 --image $IMG
```

| 결과 | 의미 |
|---|---|
| **통과** | **GDR 확정.** IB 자체는 정상, GPU 메모리 등록만 깨짐 |
| status=4 계속 | GDR 문제가 아님. IB 설정 쪽 → STEP 4 |

STEP 2가 통과하면 **당장 쓸 수 있는 답**이 생깁니다.
GDR 없는 IB도 TCP Socket보다 훨씬 빠릅니다. 그걸로 벤치마크를 돌리면서 GDR을 고치면 됩니다.

---

## STEP 3 — 호스트 쪽 GDR 조건 (ssh만, `git pull` 불필요)

STEP 1·2와 병행하세요. **두 노드 다** 봐야 합니다.

```bash
for h in $N1 $N2; do
  echo "=== $h ==="
  ssh $h 'lsmod | grep -E "nvidia_peermem|nv_peer_mem" || echo "peermem: NOT LOADED"'
  ssh $h 'cat /sys/module/nvidia/version 2>/dev/null; ofed_info -s 2>/dev/null | head -1'
done
```

`NOT LOADED`면 그것만으로 STEP 1이 실패합니다.

```bash
ssh <노드> 'modprobe nvidia_peermem && echo nvidia_peermem > /etc/modules-load.d/nvidia-peermem.conf'
```

### PCIe ACS — GDR을 조용히 죽이는 대표적 원인

ACS가 켜져 있으면 NIC와 GPU 사이 peer-to-peer DMA가 루트 컴플렉스로 우회되거나 차단됩니다.
`status=4`가 나오는 전형적인 조건입니다.

```bash
ssh $N1 'lspci -vvv 2>/dev/null | grep -i "ACSCtl" | grep -v "SrcValid-" | head'
```

`SrcValid+`가 보이면 ACS가 활성입니다. BIOS 또는 부팅 시 비활성화가 필요합니다.

---

## STEP 4 — HCA 목록 정리 (STEP 1·2가 다 실패했을 때)

이전 로그에 **IB와 RoCE가 섞여** 있었습니다.

```
[0]mlx5_0:1/IB/SHARP  [1]mlx5_1:1/IB/SHARP  [2]mlx5_2:1/RoCE  [3]mlx5_3:1/RoCE
[4..11] IB/SHARP      [12]mlx5_12:1/RoCE    [13]mlx5_13:1/RoCE  [14][15] IB/SHARP
```

`mlx5_2, 3, 12, 13`이 RoCE입니다. 한 job에서 IB와 RoCE를 섞으면 문제가 생깁니다.
IB만 남겨서 확인합니다.

```bash
env $COMMON \
NCCL_IB_HCA='mlx5_0,mlx5_1,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_14,mlx5_15' \
./scripts/nccl_probe.sh --hosts $N1,$N2 --image $IMG
```

---

## STEP 5 — 지금 당장 학습을 돌려야 한다면 (Socket)

느리지만 **동작은 합니다.** IB 조사와 병행해서 돌려두셔도 됩니다.

```bash
NCCL_NET_PLUGIN=none \
NCCL_NET=Socket NCCL_SOCKET_IFNAME='=bond0.3061' NCCL_SOCKET_FAMILY=AF_INET \
NCCL_IB_DISABLE=1 \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/run_multi_node.sh --hosts $N1,$N2 \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --cp 1 --mbs 1 --gbs 256 --max-steps 10
```

**정식 측정용은 아닙니다.** 노드 간 대역폭이 IB 대비 크게 떨어져서
멀티노드 스케일링 수치가 의미 없게 나옵니다. 동작 확인용으로만 쓰세요.

로그에서 런처가 고른 값도 확인해 주세요. 자동 탐지가 엉뚱한 걸 골랐을 수 있습니다.

```
NCCL_IB_HCA=...  NCCL_SOCKET_IFNAME=...  MASTER_ADDR=...
```

---

## STEP 6 — 회신

`Errors`에 붙여주세요.

1. STEP 1 — `NCCL_DMABUF_ENABLE=0` 결과
2. STEP 2 — `NCCL_NET_GDR_LEVEL=0` 결과
3. STEP 3 — 두 노드의 `nvidia_peermem` 상태, ACS
4. STEP 5를 돌렸다면 런처가 고른 `NCCL_SOCKET_IFNAME`

1과 2 중 하나만 통과해도 결론이 납니다.

---

## 따로 확인 중인 것 — `NCCL_IB_DISABLE=1`이 안 먹었습니다

2번째 시도에서 `NCCL_IB_DISABLE=1`을 줬는데도 `transport/net_ib.cc` 경고가 계속 나왔습니다.
전달은 됐을 텐데 NCCL이 무시한 모양입니다. `NCCL_NET=Socket`으로는 의도대로 됐으니
당장 막히는 건 없지만, 짚어두겠습니다. STEP 1·2 로그에서 같이 보겠습니다.

---

## 알려진 미해결 — 로그 저장 위치

`log_dir`이 GPU 노드의 `/opt/poc-platform/mlperf_logs_train_v51/...`로 갑니다.
컨테이너 내부 경로가 아니라 **GPU 노드의 실제 경로**입니다 (같은 경로로 bind-mount됨).

`--log-root` 플래그는 이미 있지만 기본값이 스크립트에 박혀 있어 `.env`로는 못 바꿉니다.
`.env`에서 지정 가능하게 고치겠습니다. 그전까지는 이렇게 넘기면 됩니다.

```bash
./scripts/run_multi_node.sh ... --log-root /mgmt/server/poc-platform/mlperf_logs_train_v51
```

---

## 확정된 사실 (기록용)

| 항목 | 결과 |
|---|---|
| 단일 노드 학습 8장 | **통과** |
| 멀티노드 NCCL (Socket) | **통과 — 16 GPU all-reduce** |
| 멀티노드 NCCL (IB) | 실패 — `status=4` local protection error |
| `ib_write_bw` | 통과. 단 **호스트 메모리 기준**이라 GDR 검증 아님 |
| 이전 SIGSEGV 원인 | HPC-X `libnccl-net.so` ↔ NCCL 2.28.3 불일치 |
| 그 해결 | `NCCL_NET_PLUGIN=none` (B300 기본값, `489dc11`) |
| 드라이버 | 580.173.02 (r580) — 정상 |
| 호스트 NCCL / HPC-X | 컨테이너와 무관 |
