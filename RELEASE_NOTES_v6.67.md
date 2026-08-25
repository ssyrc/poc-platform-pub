# v6.67

## MLPerf bare-metal multi-node RDMA auto-binding

- Added per-host GPU-to-NIC auto-detection for MLPerf bare-metal multi-node Training.
- `nvidia-smi topo -m` is parsed for the selected GPUs using `PIX -> PXB -> PHB -> NODE -> SYS` affinity priority.
- The selected NIC legend entries are converted to HCA names such as `mlx5_0` and passed as `NCCL_IB_HCA`.
- `ibdev2netdev` maps selected HCAs to Linux netdevs; only UP interfaces with a global IP are used for `NCCL_SOCKET_IFNAME`.
- When `MASTER_ADDR` is not explicitly set, rank 0 uses the first detected compute-net IP; otherwise it falls back to the first host identifier.
- Auto-detection is performed independently on every host, so NIC/HCA numbering does not need to match between servers.
- Explicit `NCCL_IB_HCA`, `NCCL_SOCKET_IFNAME`, and `MASTER_ADDR` values override automatic selection.
- Forwarded multi-node/NCCL variables through SSH and into Docker for both MLPerf Training v4.1 and v5.1.
- Added automatic `/dev/infiniband/*` device passthrough to MLPerf Training Docker containers.
- Fixed Docker forwarding of `MLPERF_TRAIN_NNODES`, `MLPERF_NODE_RANK`, `MLPERF_WORLD_SIZE`, and `WORLD_SIZE_GPUS`.
