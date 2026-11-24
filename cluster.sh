#!/usr/bin/env bash
# cluster.sh — docker compose front-end for the 2x DGX Spark DeepSeek-V4.1-Flash recipe.
#
# Run on the HEAD node. The worker (rank 1) is reached keylessly via $WORKER_SSH and must
# hold this same checkout at $WORKER_REPO (default: the same absolute path as the head) plus
# the same .env values for MODEL_VIEW, CACHE_DIR and IMAGE. docker/build.sh ships the image
# to the worker and verifies both nodes agree. See docs/COMPOSE.md.
#
#   ./cluster.sh up       preflight -> CUDA extensions -> rank 0 -> store port -> rank 1 -> wait for API
#   ./cluster.sh down     stop + remove both rank containers (./stop.sh archives the logs first)
#   ./cluster.sh status   containers + API (same as ./status.sh)
#   ./cluster.sh verify   5-check smoke test (same as ./verify.sh)
#   ./cluster.sh logs [N] tail both rank logs (default 100 lines)
#
# Equivalent to ./start.sh: the containers are declared in docker-compose.yml instead of a
# raw docker run, and the tested startup order (rank 0 first, wait for the rendezvous store
# port, then rank 1) is preserved.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/scripts/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_REPO="${WORKER_REPO:-$HERE}"

# Compose -f args for the checkout living at $1 (shell-quoted, safe to embed in ssh too).
cf_args() {
  local -a cf=(-f "$1/docker-compose.yml")
  [ -n "${API_KEY_FILE:-}" ] && cf+=(-f "$1/docker-compose.secured.yml")
  printf '%q ' "${cf[@]}"
}

check_key_file() {  # $1 = head|worker
  if [ -n "${API_KEY_FILE:-}" ]; then
    if [ "$1" = head ]; then
      [ -f "$API_KEY_FILE" ] || { log "API_KEY_FILE is set but not found on the head: $API_KEY_FILE"; exit 1; }
    else
      wssh "test -f $(printf '%q' "$API_KEY_FILE")" || { log "API_KEY_FILE is set but not found on the worker: $API_KEY_FILE"; exit 1; }
    fi
  fi
}

cmd="${1:-up}"
case "$cmd" in
  up)
    "$HERE/scripts/preflight.sh"
    "$HERE/scripts/build_extensions.sh"
    check_key_file head
    check_key_file worker
    wssh "mkdir -p '$CACHE_DIR'"
    CFH="$(cf_args "$HERE")"
    CFW="$(cf_args "$WORKER_REPO")"

    log "starting rank 0 on the head"
    # shellcheck disable=SC2086
    docker compose $CFH down tfv41-r0 --timeout 60 >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker compose $CFH up -d tfv41-r0

    log "waiting for the rendezvous store port ($STORE_PORT)"
    for _ in $(seq 1 120); do
      ss -ltn | grep -q ":$STORE_PORT " && break
      sleep 2
    done
    if ! ss -ltn | grep -q ":$STORE_PORT "; then
      log "rank 0 never opened port $STORE_PORT"
      docker logs --tail 40 tfv41-r0
      exit 1
    fi

    log "starting rank 1 on the worker ($WORKER_SSH)"
    # shellcheck disable=SC2086
    wssh "cd $(printf '%q' "$WORKER_REPO") && docker compose $CFW down tfv41-r1 --timeout 60 >/dev/null 2>&1 || true; docker compose $CFW up -d tfv41-r1"

    log "waiting for $API/models (the first start writes the rank caches: slow)"
    for _ in $(seq 1 360); do
      if healthy; then
        log "serving $SERVED_NAME at $API"
        margin_check
        exit 0
      fi
      docker ps --format '{{.Names}}' | grep -q '^tfv41-r0$' || { log "tfv41-r0 exited"; docker logs --tail 60 tfv41-r0; exit 1; }
      wssh "docker ps --format '{{.Names}}'" | grep -q '^tfv41-r1$' || { log "tfv41-r1 exited"; wssh "docker logs --tail 60 tfv41-r1"; exit 1; }
      sleep 10
    done
    log "not ready after 60 min"
    exit 1
    ;;
  down)
    log "stopping both ranks (run ./stop.sh first if you want the logs archived)"
    # shellcheck disable=SC2086
    docker compose $(cf_args "$HERE") down tfv41-r0 --timeout 60 || true
    wssh "cd $(printf '%q' "$WORKER_REPO") && docker compose $(cf_args "$WORKER_REPO") down tfv41-r1 --timeout 60 || true"
    log "stopped"
    ;;
  status)
    exec "$HERE/status.sh"
    ;;
  verify)
    exec "$HERE/verify.sh"
    ;;
  logs)
    tail_n="${2:-100}"
    docker logs --tail "$tail_n" tfv41-r0 2>/dev/null || echo "(no tfv41-r0 logs)"
    echo "=== worker ==="
    wssh "docker logs --tail $tail_n tfv41-r1 2>/dev/null || echo '(no tfv41-r1 logs)'"
    ;;
  *)
    echo "usage: $0 [up|down|status|verify|logs [N]]" >&2
    exit 2
    ;;
esac
