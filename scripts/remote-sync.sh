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
export AGMSG_SYNC_TRUST_DIR="${AGMSG_SYNC_TRUST_DIR:-${AGMSG_SYNC_CONNECTION_DIR:-$SKILL_DIR}/run/remote-trust}"
export AGMSG_SYNC_DRIVER="$SCRIPT_DIR/internal/storage-sync-driver.sh"
NODE_BIN="$(agmsg_resolve_node)"
export AGMSG_SYNC_NODE_BIN="$NODE_BIN"
export AGMSG_SYNC_CIPHER_HELPER="$SCRIPT_DIR/internal/sync-cipher.mjs"
# The engine outlives the command that starts it, so whatever it inherits it
# holds for as long as it runs — including a descriptor internal to bats,
# which then waits for an EOF that cannot arrive. Closing 3 and 4 by name
# cannot reach it, because the harness picks the number.
# The range close and the reasoning behind it now live in lib/close-fds.sh,
# because codex-bridge-launcher.sh needs exactly the same thing and had the
# insufficient by-name form until a macOS shard hung on it.
. "$SCRIPT_DIR/lib/close-fds.sh"
agmsg_close_inherited_fds

exec "$NODE_BIN" "$SCRIPT_DIR/internal/remote-sync.mjs" "$@"
