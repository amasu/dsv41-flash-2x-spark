# Docker Compose deployment

`docker-compose.yml` is a docker compose front-end for the exact recipe `start.sh` deploys with
raw `docker run`: same image, same mounts, same environment, same ulimits/caps/devices, same
engine flags. The two entry points are interchangeable.

## Why two services, one node each

TensorFold TP=2 needs one container per node. `docker compose` cannot start a service on a
different machine, so `cluster.sh` runs one `docker compose up -d <service>` per node, in the
tested order:

| Service | Node | Role |
|---|---|---|
| `tfv41-r0` | head (`$HEAD_IP`) | rank 0, master; serves the OpenAI-compatible API on `$PORT` |
| `tfv41-r1` | worker (`$WORKER_SSH`) | rank 1; joins rank 0 over the RoCE link, no HTTP |

`./cluster.sh up` does, on the head:

1. `scripts/preflight.sh` — both nodes (RoCE MTU 4096, GID type, memory, disk, images, port)
2. `scripts/build_extensions.sh` — CUDA extension build on both nodes (fast once cached)
3. `docker compose up -d tfv41-r0` (head)
4. wait for the rendezvous store port `$STORE_PORT` (29551) to listen on the head
5. `docker compose up -d tfv41-r1` on the worker (via ssh)
6. poll `/v1/models` until it answers with the served name, then print the memory margin

Manual equivalent:

```bash
# head:
docker compose -f docker-compose.yml up -d tfv41-r0
# worker (same checkout + .env):
docker compose -f docker-compose.yml up -d tfv41-r1
```

The worker must hold the same checkout (default: the same absolute path as the head; override
with `WORKER_REPO` in `.env`) and the same `.env` values for `MODEL_VIEW`, `CACHE_DIR`,
`HEAD_IP` and `IMAGE`. `docker/build.sh` builds the image on the head, ships it to the worker
and verifies both nodes hold the same image ID.

## Other subcommands

```bash
./cluster.sh status   # containers + API (same as ./status.sh)
./cluster.sh verify   # 5-check smoke test (same as ./verify.sh)
./cluster.sh logs [N] # tail both rank logs
./cluster.sh down     # stop + remove both rank containers
```

`./stop.sh` remains the preferred stop when you want the container logs archived to `logs/`
first; `cluster.sh down` does the same thing without archiving.

## API key

The base file serves **without** a key — that is how the 2026-11-24 test run was served
(`0.0.0.0:8000`, open on the LAN). To enable key auth:

1. create a key file with one key per line (`chmod 600`) on **both** nodes;
2. set `API_KEY_FILE` in `.env`;
3. start with the overlay — `cluster.sh` does this automatically:

```bash
docker compose -f docker-compose.yml -f docker-compose.secured.yml up -d tfv41-r0
```

Compose replaces (not appends) lists on merge, so the overlay restates rank 0's `volumes` and
`command` in full, adding the key mount and `--api-key-file /run/keys`. Rank 1 is untouched:
it never serves HTTP.

## Per-rank RDMA device names

The two nodes are allowed to name their RoCE devices differently. On the 2026-11-24 nodes the
head exposes `mlx5_1,mlx5_3` while the worker exposes `rocep1s0f1,roceP2p1s0f1`. Because
`TF_RDMA_DEVICES` is a per-rank engine setting:

- `docker-compose.yml` sets `TF_RDMA_DEVICES` from `RDMA_DEVICES_HEAD` on `tfv41-r0` and from
  `RDMA_DEVICES_WORKER` on `tfv41-r1`, each falling back to `RDMA_DEVICES`;
- `start.sh` and `scripts/preflight.sh` make the same per-rank selection — that is the only
  functional change vs. upstream (one line each; `git log` shows the diff).

`NCCL_IB_HCA` stays a union list on both nodes (NCCL tolerates device names it does not find,
and the union is what the tested run used).

## What the compose file pins

Defaults match the tested recipe (`env.tested-2x-spark` is the exact `.env` of the 2026-11-24
run): 1M context, parallel 4, MTP drafts 5, prefill chunk 2048, spill 64 GiB, mem floor
1.5 GiB, no-swap `tensorfold.slice`, 32 g `/dev/shm`, `memlock` unlimited, stack 64 MiB,
`/dev/infiniband` passthrough, `IPC_LOCK` + `SYS_PTRACE`, RoCE GID index 3, `HF_HUB_OFFLINE=1`.
Two more runtime knobs are tunable via `.env`: `SHM_SIZE` (default `32g`, the `/dev/shm` size)
and `OOM_SCORE_ADJ` (default `1000`, docker `--oom-score-adj`).

Opt-in switches `start.sh` also exposes (`MEM_CAP=1`, `STRICT_TOOL_OUTPUT=0`, `VISION=1`,
`THINKING=1` / `REASONING_EFFORT`) are a one-line edit to the `command:` list (or env for
`TF_DS_MEM_CAP` / `TF_DS_STRICT_TOOL_OUTPUT`) — or just use `./start.sh`, which remains
equivalent.

## Test run (2026-11-24)

See `runs/2026-11-24/` — the full recipe redeployed on two DGX Sparks (head
10.100.90.1 / worker 10.100.90.4, RoCE MTU 4096 on both links, GID 3) and benched from the
client machine with tool-eval-bench dev7 hardmode: **93/100** (forum reference: 97/100).
