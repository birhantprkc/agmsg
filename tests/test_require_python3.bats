#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/require-python3.sh"
}

teardown() {
  teardown_test_env
}

# --- agmsg_python3_usable: the real environment ----------------------------

@test "python3_usable: reflects reality when python3 is genuinely absent" {
  _agmsg_python3_resolved_path() { printf ''; }
  run agmsg_python3_usable
  [ "$status" -ne 0 ]
}

# --- co1 P1 finding: macOS CLT trampoline ------------------------------------
# On Darwin, /usr/bin/python3 exists on PATH (so a bare `command -v python3`
# succeeds) even when Xcode Command Line Tools are NOT installed -- it's a
# trampoline that pops the OS's own "install command line developer tools?"
# dialog the moment it is actually executed, not a real interpreter. These
# tests simulate that exact state via function/PATH overrides, WITHOUT ever
# touching the real python3 or xcode-select on this machine, and without
# depending on this machine's actual CLT install state.

@test "python3_usable: Darwin + /usr/bin/python3 + CLT installed -> usable" {
  _agmsg_python3_resolved_path() { printf '/usr/bin/python3'; }
  _agmsg_platform() { printf 'Darwin'; }
  local fakebin; fakebin="$(mktemp -d)"
  cat > "$fakebin/xcode-select" <<'EOF'
#!/usr/bin/env bash
echo "/Library/Developer/CommandLineTools"
exit 0
EOF
  chmod +x "$fakebin/xcode-select"
  PATH="$fakebin:$PATH" run agmsg_python3_usable
  [ "$status" -eq 0 ]
}

@test "python3_usable: Darwin + /usr/bin/python3 + CLT NOT installed -> NOT usable (the actual bug co1 found)" {
  _agmsg_python3_resolved_path() { printf '/usr/bin/python3'; }
  _agmsg_platform() { printf 'Darwin'; }
  local fakebin; fakebin="$(mktemp -d)"
  cat > "$fakebin/xcode-select" <<'EOF'
#!/usr/bin/env bash
echo "xcode-select: error: unable to get active developer directory" >&2
exit 2
EOF
  chmod +x "$fakebin/xcode-select"
  PATH="$fakebin:$PATH" run agmsg_python3_usable
  [ "$status" -ne 0 ]
}

@test "python3_usable: Darwin + a non-trampoline resolved path (Homebrew) is usable even with CLT absent" {
  _agmsg_python3_resolved_path() { printf '/opt/homebrew/bin/python3'; }
  _agmsg_platform() { printf 'Darwin'; }
  local fakebin; fakebin="$(mktemp -d)"
  cat > "$fakebin/xcode-select" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$fakebin/xcode-select"
  # xcode-select is on PATH but must never even be consulted for a
  # non-/usr/bin/python3 resolved path -- only the Darwin+trampoline-path
  # combination triggers the extra check.
  PATH="$fakebin:$PATH" run agmsg_python3_usable
  [ "$status" -eq 0 ]
}

@test "python3_usable: non-Darwin platform never runs the CLT check even at the trampoline-shaped path" {
  _agmsg_python3_resolved_path() { printf '/usr/bin/python3'; }
  _agmsg_platform() { printf 'Linux'; }
  # No xcode-select on PATH at all -- if the CLT check ran here, it would
  # crash on "command not found" rather than just passing. It must not run.
  run agmsg_python3_usable
  [ "$status" -eq 0 ]
}

@test "python3_usable: never invokes python3 itself in any branch" {
  # A python3 that would fail loudly (or, in spirit, pop a dialog) if ever
  # executed -- proves the check never runs it, on the exact trampoline path.
  _agmsg_python3_resolved_path() { printf '/usr/bin/python3'; }
  _agmsg_platform() { printf 'Darwin'; }
  local fakebin; fakebin="$(mktemp -d)"
  cat > "$fakebin/xcode-select" <<'EOF'
#!/usr/bin/env bash
echo "/Library/Developer/CommandLineTools"
exit 0
EOF
  chmod +x "$fakebin/xcode-select"
  cat > "$fakebin/python3" <<'EOF'
#!/usr/bin/env bash
echo "SHOULD NEVER RUN" >&2
exit 99
EOF
  chmod +x "$fakebin/python3"
  PATH="$fakebin:$PATH" run agmsg_python3_usable
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NEVER RUN"* ]]
}

# --- agmsg_require_python3: the user-facing wrapper -------------------------

@test "require_python3: prints an install message and fails when not usable" {
  _agmsg_python3_resolved_path() { printf ''; }
  run agmsg_require_python3 "remote connect"
  [ "$status" -ne 0 ]
  [[ "$output" == *"remote connect requires python3"* ]]
  [[ "$output" == *"brew install python3"* ]]
}

@test "require_python3: silent success when usable" {
  _agmsg_python3_resolved_path() { printf '/opt/homebrew/bin/python3'; }
  _agmsg_platform() { printf 'Darwin'; }
  run agmsg_require_python3 "remote connect"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
