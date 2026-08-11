#!/usr/bin/env bats

# A team on a private CA is served by two HTTP clients, and they read different
# variables: this script's own calls go through curl, and everything it starts
# -- the persistent sync engine, the team-name lookup -- is Node. Setting the
# one that makes `connect` succeed leaves the engine with no trust at all, and
# it then fails every cycle forever while `status` still says "engine running"
# (#744). Nothing warns, because from each client's own side nothing is wrong.
#
# These pin the single setting that feeds both, and the refusal that keeps a
# half-configured run from starting.

load test_helper

# remote.sh has no "sourced" guard -- its dispatcher runs and exits on source --
# so these lift the block out of the real file by its own boundaries rather than
# by line number. Hardcoding the range would keep passing while measuring
# whatever moved into it.
ca_block() {
  awk '/^if \[ -n "\$\{AGMSG_CA_CERT:-\}" \]; then$/,/^fi$/' "$SCRIPTS/remote.sh"
}

setup() {
  setup_test_env
  CA="$TEST_SKILL_DIR/ca.pem"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'not-a-real-cert' '-----END CERTIFICATE-----' > "$CA"
  BLOCK="$TEST_SKILL_DIR/ca-block.sh"
  ca_block > "$BLOCK"
  # If the block stops being liftable, every test below would pass vacuously on
  # an empty file. Fail here instead.
  [ -s "$BLOCK" ]
  grep -q 'NODE_EXTRA_CA_CERTS' "$BLOCK"
}

teardown() { teardown_test_env; }

@test "remote: AGMSG_CA_CERT reaches BOTH the curl variable and the Node one (#744)" {
  run env AGMSG_CA_CERT="$CA" bash -c \
    ". '$BLOCK'; printf 'CURL=%s\nNODE=%s\n' \"\${CURL_CA_BUNDLE:-unset}\" \"\${NODE_EXTRA_CA_CERTS:-unset}\""
  [ "$status" -eq 0 ]
  grep -qF "CURL=$CA" <<<"$output"
  grep -qF "NODE=$CA" <<<"$output"
}

@test "remote: with nothing set, neither variable is invented (#744)" {
  run env -u AGMSG_CA_CERT -u CURL_CA_BUNDLE -u NODE_EXTRA_CA_CERTS bash -c \
    ". '$BLOCK'; printf 'CURL=%s\nNODE=%s\n' \"\${CURL_CA_BUNDLE:-unset}\" \"\${NODE_EXTRA_CA_CERTS:-unset}\""
  [ "$status" -eq 0 ]
  grep -qF "CURL=unset" <<<"$output"
  grep -qF "NODE=unset" <<<"$output"
}

@test "remote: an explicit upstream setting is not overwritten (#744)" {
  local other="$TEST_SKILL_DIR/other.pem"
  cp "$CA" "$other"
  run env AGMSG_CA_CERT="$CA" CURL_CA_BUNDLE="$other" bash -c \
    ". '$BLOCK'; printf 'CURL=%s\nNODE=%s\n' \"\${CURL_CA_BUNDLE:-unset}\" \"\${NODE_EXTRA_CA_CERTS:-unset}\""
  [ "$status" -eq 0 ]
  grep -qF "CURL=$other" <<<"$output"
  grep -qF "NODE=$CA" <<<"$output"
}

@test "remote: an unreadable AGMSG_CA_CERT is refused before anything runs (#744)" {
  # Refused here rather than later: a path only one client can open produces the
  # exact failure this whole change exists to prevent, one layer further away.
  run env AGMSG_CA_CERT="$TEST_SKILL_DIR/absent.pem" bash "$SCRIPTS/remote.sh" status
  [ "$status" -ne 0 ]
  grep -qF "AGMSG_CA_CERT is set but not readable" <<<"$output"
  grep -qF "absent.pem" <<<"$output"
}
