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
#
# `command -v python3` alone is NOT sufficient to detect this (co1 review,
# P1): the trampoline file genuinely exists at /usr/bin/python3, so
# `command -v` reports success even when CLT is not installed -- the
# dialog only fires once something actually EXECUTES it. So on Darwin,
# when python3 resolves to exactly /usr/bin/python3, an additional check
# is required: `xcode-select -p` reports whether CLT (or a full Xcode) is
# actually installed. It is safe to call -- unlike python3 itself, it is a
# real, always-present binary that only inspects installed-tool state and
# never pops a GUI dialog; it just exits non-zero with no CLT installed.
# On any other resolved path (Homebrew, pyenv, apt, etc.), or on a
# non-Darwin platform, there is no trampoline to worry about and
# `command -v` alone is authoritative.
#
# python3 itself is NEVER executed by this check, on any platform.
#
# core (local-only) and E2EE (age) tiers never source this file and never
# need python3; only remote-tier code should call it.

# Indirection points so tests can substitute fakes without touching real
# filesystem paths or fighting `command -v`'s exact-string PATH lookup --
# bash resolves a called function by name from the function table before
# ever consulting PATH, so a test that re-defines these after sourcing
# this file transparently overrides them for agmsg_python3_usable.
_agmsg_python3_resolved_path() { command -v python3 2>/dev/null; }
_agmsg_platform() { uname -s 2>/dev/null; }

# agmsg_python3_usable -- 0 if python3 is present AND safe to invoke
# without risking the macOS CLT dialog, 1 otherwise. Never executes
# python3.
agmsg_python3_usable() {
  local resolved
  resolved="$(_agmsg_python3_resolved_path)"
  [ -n "$resolved" ] || return 1
  if [ "$(_agmsg_platform)" = "Darwin" ] && [ "$resolved" = "/usr/bin/python3" ]; then
    xcode-select -p >/dev/null 2>&1 || return 1
  fi
  return 0
}

agmsg_require_python3() {
  local feature="${1:-this feature}"
  if ! agmsg_python3_usable; then
    echo "agmsg: $feature requires python3, which was not found (or not yet usable) on this device." >&2
    echo "Install it, then retry:" >&2
    echo "  macOS (Homebrew):      brew install python3" >&2
    echo "  macOS (Xcode tools):   xcode-select --install" >&2
    echo "  Debian/Ubuntu:         sudo apt install python3" >&2
    echo "  Windows (winget):      winget install Python.Python.3" >&2
    return 1
  fi
}
