#!/usr/bin/env bash
# Private adapter between the Node polling engine and sourced storage drivers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/storage.sh"
agmsg_storage_load

op="${1:-}"; shift || true
case "$op" in
  prepare)   command -v storage_sync_prepare_push >/dev/null 2>&1 || exit 14
             storage_sync_prepare_push "$@" ;;
  reconcile) command -v storage_sync_reconcile_push >/dev/null 2>&1 || exit 14
             storage_sync_reconcile_push "$@" ;;
  apply)     command -v storage_sync_apply_pull >/dev/null 2>&1 || exit 14
             storage_sync_apply_pull "$@" ;;
  reprocess) command -v storage_sync_reprocess >/dev/null 2>&1 || exit 14
             storage_sync_reprocess "$@" ;;
  *) echo "usage: storage-sync-driver.sh prepare|reconcile|apply|reprocess ..." >&2; exit 2 ;;
esac
