#!/usr/bin/env bash
# Stage-1 polling synchronization client (dogfood; docs/spec/ref/stage-1-remote-sync.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/node.sh"
export AGMSG_SYNC_STORAGE_DIR="$(agmsg_storage_dir)"
export AGMSG_SYNC_DRIVER="$SCRIPT_DIR/internal/storage-sync-driver.sh"
NODE_BIN="$(agmsg_resolve_node)"
export AGMSG_SYNC_NODE_BIN="$NODE_BIN"
export AGMSG_SYNC_CIPHER_HELPER="$SCRIPT_DIR/internal/sync-cipher.mjs"
exec "$NODE_BIN" "$SCRIPT_DIR/internal/remote-sync.mjs" "$@"
