[root@node-26051 poc-platform-pub]# TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO ./scripts/nccl_probe.sh --hosts node26,node27,node28,node29,node30 --image $IMG 2>&1 | tee /mgmt/server/nccl_probe.log
Warning: Permanently added 'node26' (ED25519) to the list of known hosts.
[INFO] gpus_per_node=8 (detected on node26: NVIDIA B300 SXM6 AC)
[INFO] B300 detected: NCCL_NET_PLUGIN=none (HPC-X plugin crashes ncclCommInitRankConfig)
[INFO] mode=multi nnodes=5 hosts=node26 node27 node28 node29 node30 gpus_per_node=8
[INFO] rendezvous=node26:29500 (rank 0 = node26), join window 600s
[INFO] image=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
[INFO] env into container: PROBE_EXPECTED_WORLD=40 PROBE_EXPECTED_HOSTS=node26,node27,node28,node29,node30 NCCL_NET_PLUGIN=none NCCL_IB_DISABLE= NCCL_IB_HCA= NCCL_SOCKET_IFNAME=
[WARN] clocks differ by 45s across hosts (node29 .. node26)
[WARN] not fatal -- runs succeed at this skew -- but worth fixing:
[WARN]   chronyc makestep   on the hosts that are out
[INFO] checking node26:29500 is reachable from every host
  node26         ok (refused)  via local node26 dev lo src node26 uid 0
  node27         ok (refused)  via node26 dev bond0.3061 src node27 uid 0
  node28         ok (refused)  via node26 dev bond0.3061 src node28 uid 0
  node29         ok (refused)  via node26 dev bond0.3061 src node29 uid 0
  node30         ok (refused)  via node26 dev bond0.3061 src node30 uid 0

[node29] [REMOTE] node_rank=3 nproc_per_node=8 starting torchrun at 01:40:10
[node29] [LAUNCH] torchrun --nnodes=5 --node_rank=3 --nproc_per_node=8 --rdzv_backend=c10d --rdzv-id=probe_31320_1787935247 --rdzv_endpoint=node26:29500 --rdzv-conf=timeout=600,read_timeout=600
[node28] [REMOTE] node_rank=2 nproc_per_node=8 starting torchrun at 01:40:41
[node28] [LAUNCH] torchrun --nnodes=5 --node_rank=2 --nproc_per_node=8 --rdzv_backend=c10d --rdzv-id=probe_31320_1787935247 --rdzv_endpoint=node26:29500 --rdzv-conf=timeout=600,read_timeout=600
[node30] [REMOTE] node_rank=4 nproc_per_node=8 starting torchrun at 01:40:19
[node30] [LAUNCH] torchrun --nnodes=5 --node_rank=4 --nproc_per_node=8 --rdzv_backend=c10d --rdzv-id=probe_31320_1787935247 --rdzv_endpoint=node26:29500 --rdzv-conf=timeout=600,read_timeout=600
[node30] [REMOTE] node_rank=4 nproc_per_node=8 starting torchrun at 01:40:19
[node30] [LAUNCH] torchrun --nnodes=5 --node_rank=4 --nproc_per_node=8 --rdzv_backend=c10d --rdzv-id=probe_31320_1787935247 --rdzv_endpoint=node26:29500 --rdzv-conf=timeout=600,read_timeout=600
[node27] [REMOTE] node_rank=1 nproc_per_node=8 starting torchrun at 01:40:50
[node27] [LAUNCH] torchrun --nnodes=5 --node_rank=1 --nproc_per_node=8 --rdzv_backend=c10d --rdzv-id=probe_31320_1787935247 --rdzv_endpoint=node26:29500 --rdzv-conf=timeout=600,read_timeout=600


====================================================================
PER-HOST RESULT
====================================================================
  rank host                 exit   note
  ----------------------------------------------------------------
  0    node26         0      ok
  1    node27         0      ok
  2    node28         1      torch.distributed.DistNetworkError: Failed to recv, got 0 bytes. Connection was likely closed. Did t
  3    node29         1      torch.distributed.DistNetworkError: Failed to recv, got 0 bytes. Connection was likely closed. Did t
  4    node30         1      torch.distributed.DistNetworkError: Failed to recv, got 0 bytes. Connection was likely closed. Did t
  ----------------------------------------------------------------
  world formed: 16/40 ranks, 2/5 nodes
  [FAIL] 24 rank(s) short -- the hosts above with a
         non-zero exit are the ones that did not join
====================================================================
