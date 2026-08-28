#!/usr/bin/env python3
"""Minimal NCCL bring-up check -- who joined, whether the collective is correct,
and how fast it runs. Nothing else.

The training runs load NeMo, Megatron, TransformerEngine and Lightning before
NCCL is reached, so a failure there could belong to any of them. This carries
none of it, and reports what a multi-node failure actually needs:

  - which nodes joined, and with how many ranks each
  - whether that matches what was asked for, and which nodes are missing
  - whether the all-reduce result is correct
  - the bandwidth it achieved

Run it under torchrun:

  torchrun --standalone --nproc_per_node=8 nccl_probe.py
"""
import datetime
import os
import socket
import sys

import torch
import torch.distributed as dist

rank = int(os.environ["RANK"])
local_rank = int(os.environ["LOCAL_RANK"])
world_size = int(os.environ["WORLD_SIZE"])
# What the launcher intended, so a short world can be named rather than guessed.
expected_world = int(os.environ.get("PROBE_EXPECTED_WORLD") or world_size)
expected_hosts = [h for h in (os.environ.get("PROBE_EXPECTED_HOSTS") or "").split(",") if h]


def log(msg):
    print(f"[probe r{rank}] {msg}", flush=True)


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.0f} {unit}"
        n /= 1024


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

# Who actually made it in. Collected before any collective that could hang, so
# the roster survives even if the numbers below go wrong.
me = (socket.gethostname(), rank, local_rank, name)
roster = [None] * world_size
dist.all_gather_object(roster, me)

tensor = torch.ones(1024, 1024, device=f"cuda:{local_rank}")
log("all_reduce ...")
dist.all_reduce(tensor)
torch.cuda.synchronize()
got = tensor.flatten()[0].item()
correct = got == float(world_size)
if not correct:
    log(f"all_reduce WRONG RESULT: {got} != {world_size}")
log(f"all_reduce OK (= {got})")

# Bandwidth. Ring all-reduce moves 2*(n-1)/n of the buffer per rank, which is
# what makes busbw comparable across world sizes -- algbw alone is not.
SIZES = [8 << 20, 64 << 20, 256 << 20]
ITERS, WARMUP = 20, 5
results = []
for nbytes in SIZES:
    buf = torch.empty(nbytes // 4, dtype=torch.float32, device=f"cuda:{local_rank}")
    for _ in range(WARMUP):
        dist.all_reduce(buf)
    torch.cuda.synchronize()
    dist.barrier()
    start = torch.cuda.Event(enable_timing=True)
    end = torch.cuda.Event(enable_timing=True)
    start.record()
    for _ in range(ITERS):
        dist.all_reduce(buf)
    end.record()
    torch.cuda.synchronize()
    secs = start.elapsed_time(end) / 1000.0 / ITERS
    algbw = nbytes / secs / 1e9
    busbw = algbw * 2 * (world_size - 1) / world_size
    results.append((nbytes, secs, algbw, busbw))
    del buf
    torch.cuda.empty_cache()

dist.barrier()

if rank == 0:
    by_host = {}
    for host, r, lr, dev in roster:
        by_host.setdefault(host, []).append(r)

    print("\n" + "=" * 68, flush=True)
    print("PARTICIPATING NODES", flush=True)
    print("=" * 68, flush=True)
    print(f"  {'node':<28} {'ranks':<8} {'rank ids':<24}", flush=True)
    print("  " + "-" * 64, flush=True)
    for host in sorted(by_host):
        rs = sorted(by_host[host])
        span = f"{rs[0]}-{rs[-1]}" if len(rs) > 1 else str(rs[0])
        print(f"  {host:<28} {len(rs):<8} {span:<24}", flush=True)
    print("  " + "-" * 64, flush=True)
    print(f"  {'total':<28} {world_size:<8} nodes: {len(by_host)}", flush=True)

    if world_size != expected_world:
        missing = expected_world - world_size
        print(f"\n  [MISMATCH] expected world {expected_world}, got {world_size} "
              f"({missing} rank(s) short)", flush=True)
        print("  The nodes listed above are the ones that joined; any host given", flush=True)
        print("  to the launcher and absent here never reached the rendezvous.", flush=True)

    print("\n" + "=" * 68, flush=True)
    print("ALL-REDUCE BANDWIDTH", flush=True)
    print("=" * 68, flush=True)
    print(f"  {'size':>10} {'time':>12} {'algbw':>14} {'busbw':>14}", flush=True)
    print("  " + "-" * 64, flush=True)
    for nbytes, secs, algbw, busbw in results:
        print(f"  {human(nbytes):>10} {secs*1e3:>9.2f} ms {algbw:>11.2f} GB/s {busbw:>11.2f} GB/s", flush=True)
    print("  " + "-" * 64, flush=True)
    print("  busbw is the comparable number across world sizes.", flush=True)
    print("=" * 68 + "\n", flush=True)

dist.destroy_process_group()

if not correct:
    sys.exit(1)
if world_size != expected_world:
    sys.exit(2)
if rank == 0:
    log(f"ALL OK -- {world_size} ranks across {len(by_host)} node(s)")
