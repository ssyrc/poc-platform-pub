# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (2회차)
- 대상 증상: training v5.1 단일노드 실행 중 UCX segfault

---

## 지난 회차에서 좁혀진 것

| 확인 | 결과 |
|---|---|
| IB NIC 상태 | 전부 ACTIVE / link up — **호스트 IB 정상** |
| 컨테이너에서 `ucx_info -d` | IB 장치 유무와 무관하게 **크래시 없이 실행됨** |
| 런처 코드 | 원본 zip 대비 실행 경로 변경 없음 |

UCX 초기화 자체는 멀쩡합니다. 따라서 "UCX가 통째로 깨졌다"는 가설은 탈락입니다.

**다만 지난 테스트는 `head -40`에 잘려서 `self` transport까지만 보였습니다.**
IB transport(`rc_mlx5`, `dc_mlx5`)가 목록에 있는지, 그게 정상인지는 아직 못 봤습니다.

그리고 로그에 새 단서가 나왔습니다.

```
NOTE: Mellanox network driver detected, but NVIDIA peer memory driver not detected.
```

`nvidia_peermem` 커널 모듈이 안 올라와 있습니다. GPUDirect RDMA용 모듈이고, 이게 없는 상태에서
UCX가 GPU 메모리를 IB로 등록하려 하면 죽을 수 있습니다. **현재 1순위 용의자입니다.**

---

## 준비

```bash
NODE=<대상 노드 IP 또는 호스트명>
IMAGE=donnmyth/mlperf-nvidia:llama2_70b_lora-pyt-sm90
```

---

## STEP 1 — `nvidia_peermem` 확인 및 로드  ← 최우선

```bash
ssh $NODE 'lsmod | grep -iE "nvidia_peermem|nv_peer_mem"'
```

아무것도 안 나오면 로드합니다.

```bash
ssh $NODE 'modprobe nvidia_peermem && lsmod | grep -i peermem'
```

로드에 실패하면 메시지를 그대로 `Errors`에 남겨주세요 (드라이버 버전 불일치일 수 있습니다).

로드에 성공했으면 **바로 STEP 4로 가서 실제 실행을 재시도**하세요. 이것만으로 해결될 수 있습니다.

---

## STEP 2 — UCX transport 전체 목록 (잘림 없이)

지난번 `head -40` 때문에 못 본 부분입니다. IB transport가 잡히는지 봅니다.

```bash
ssh $NODE "docker run --rm --gpus all \
  \$(for d in /dev/infiniband/*; do echo --device \$d:\$d; done) \
  $IMAGE bash -c 'ucx_info -d 2>&1' " | grep -E "^# (Memory domain|Transport|Device):" 
```

기대: `rc_verbs` / `rc_mlx5` / `dc_mlx5`와 `mlx5_*` 디바이스가 보여야 합니다.
`self` / `tcp` / `sm`만 보이면 컨테이너가 IB를 아예 못 잡고 있는 것입니다.

GPU 메모리 등록이 되는지도 함께 봅니다 (peermem 여부가 여기 반영됩니다).

```bash
ssh $NODE "docker run --rm --gpus all \
  \$(for d in /dev/infiniband/*; do echo --device \$d:\$d; done) \
  $IMAGE bash -c 'ucx_info -d 2>&1 | grep -A3 cuda'"
```

---

## STEP 3 — UCX를 공유메모리로 제한해서 실제 실행

**이제 `UCX_TLS`가 컨테이너까지 전달됩니다** (커밋 `3e4e390`에서 추가).
단일노드는 IB가 필요 없으므로 이 조합이면 UCX가 IB를 아예 안 건드립니다.

먼저 코드를 최신으로 맞추세요.

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull
```

그리고 실행합니다.

```bash
UCX_TLS=sm,self,cuda_copy,cuda_ipc \
UCX_LOG_LEVEL=warn \
./scripts/run_single_node.sh --host $NODE --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

전달됐는지는 로그의 `[INFO] advanced env forwarded:` 줄에 `UCX_TLS`가 있는지로 확인됩니다.

이걸로 통과하면 원인은 **UCX의 IB 경로**로 확정됩니다.

---

## STEP 4 — 원래 설정으로 재시도

STEP 1에서 `nvidia_peermem`을 올렸다면, 우회 없이 그대로 됩니다.

```bash
./scripts/run_single_node.sh --host $NODE --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

---

## STEP 5 — 결과 회신

`Errors`에 다음을 붙여주세요.

1. STEP 1의 `lsmod` 결과와 `modprobe` 성공/실패
2. STEP 2의 Transport/Device 목록 (`mlx5`가 보이는지)
3. STEP 3이 통과했는지 — 통과했다면 어디까지 진행됐는지 (step 로그가 찍히는지)
4. STEP 4 재시도 결과

판정 후 다음 중 하나로 진행합니다.

- `nvidia_peermem` 로드로 해결 → 노드 부팅 시 자동 로드하도록 안내
- `UCX_TLS` 우회로만 해결 → 단일노드에서 `/dev/infiniband` 패스스루를 건너뛰는 `--no-ib` 옵션 추가
- 둘 다 안 됨 → 컨테이너 안에서 `torchrun` 최소 재현 스크립트로 범위 축소

---

## 이미 확인된 것 (다시 볼 필요 없음)

**런처는 원본 그대로입니다.** 원본 zip(`32fd75b`) 대비 git diff 결과:

| 파일 | 원본 대비 |
|---|---|
| `scripts/mlperf_run.sh` | 변경 없음 |
| `scripts/common.sh` | 변경 없음 |
| `scripts/mlperf_train_v51.sh` | docker tar 폴백 + UCX env 전달만 추가 |
| `scripts/mlperf_train_v41.sh` | B300 게이팅 + tar 폴백 + UCX env 전달 |

**컨테이너 실행 인자도 정상입니다.** `--ipc=host`, `--ulimit memlock=-1`,
`--ulimit stack=67108864`, `--network=host`, `--gpus all`을 모두 넘기고 있습니다.
지난 로그의 SHMEM 경고는 진단용으로 직접 띄운 `docker run`에서 나온 것이라 실제 실행과 무관합니다.

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP와 호스트명이 그대로 들어가 있습니다. 이 저장소는 public이므로
익명화하거나 파일을 지우는 편이 좋습니다. 원하시면 정리해 드리겠습니다.
