# agmsg_require_python3 <feature description> -- preflight check before any
# python3 invocation on the "remote" dependency tier (remote.sh, team-list.sh,
# and their scripts/internal/*.py helpers). Mirrors key.sh's
# _key_require_age: the caller MUST call this before the first python3
# invocation on a given code path, not merely check python3's own exit
# status after the fact.
#
# This matters beyond a clean error message: on macOS, invoking a bare
# `python3` when Xcode Command Line Tools are not installed does not fail
# fast with "command not found" -- it triggers the OS's own "install
# command line developer tools?" GUI dialog (the /usr/bin/python3 shim is a
# CLT installer trampoline, not a real interpreter, until CLT is present).
# `command -v python3` only checks PATH for an existing file and never
# executes it, so it cannot trigger that dialog -- this is the ONLY safe
# way to detect python3's absence before code that will actually invoke it.
#
# core (local-only) and E2EE (age) tiers never source this file and never
# need python3; only remote-tier code should call it.
agmsg_require_python3() {
  local feature="${1:-this feature}"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "agmsg: $feature requires python3, which was not found on this device." >&2
    echo "Install it, then retry:" >&2
    echo "  macOS (Homebrew):      brew install python3" >&2
    echo "  macOS (Xcode tools):   xcode-select --install" >&2
    echo "  Debian/Ubuntu:         sudo apt install python3" >&2
    echo "  Windows (winget):      winget install Python.Python.3" >&2
    return 1
  fi
}
