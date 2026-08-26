#!/usr/bin/env python3
"""Minimal NCCL bring-up check -- initialisation and one all-reduce, nothing else.

The training runs die during NCCL communicator setup, but they carry NeMo,
Megatron, TransformerEngine and Lightning with them, so the crash could
belong to any of those. This carries none of it.

  passes  -> NCCL is fine on this node; the fault is above it
  crashes -> NCCL alone reproduces it; the framework stack is not involved

Run it under torchrun:

  torchrun --standalone --nproc_per_node=8 nccl_probe.py
"""
import datetime
import os
import sys

import torch
import torch.distributed as dist

rank = int(os.environ["RANK"])
local_rank = int(os.environ["LOCAL_RANK"])
world_size = int(os.environ["WORLD_SIZE"])


def log(msg):
    print(f"[probe r{rank}] {msg}", flush=True)


if rank == 0:
    log(f"torch {torch.__version__}  cuda {torch.version.cuda}  "
        f"nccl {'.'.join(str(v) for v in torch.cuda.nccl.version())}")

torch.cuda.set_device(local_rank)
name = torch.cuda.get_device_name(local_rank)
major, minor = torch.cuda.get_device_capability(local_rank)
log(f"cuda:{local_rank} {name} sm_{major}{minor}")

# This is the call the training runs die in.
log("init_process_group(nccl) ...")
dist.init_process_group("nccl", timeout=datetime.timedelta(seconds=180))
log("init_process_group OK")

tensor = torch.ones(1024, 1024, device=f"cuda:{local_rank}")
log("all_reduce ...")
dist.all_reduce(tensor)
torch.cuda.synchronize()

got = tensor.flatten()[0].item()
if got != float(world_size):
    log(f"all_reduce WRONG RESULT: {got} != {world_size}")
    dist.destroy_process_group()
    sys.exit(1)
log(f"all_reduce OK (= {got})")

dist.barrier()
dist.destroy_process_group()
if rank == 0:
    log(f"ALL OK -- {world_size} ranks")
