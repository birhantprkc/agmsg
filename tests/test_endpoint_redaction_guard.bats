#!/usr/bin/env bats

# The endpoint can carry a capability: a hosted one is `https://host/t/<token>`
# and that token IS the permission. So no message may print it raw -- every one
# goes through _remote_endpoint_display, which keeps scheme and host and drops
# path, query, fragment and userinfo.
#
# Behavioural tests cover the paths that exist today. This covers the paths
# that do not exist yet. Enumerating the messages to protect loses by one every
# time a message is added -- that is exactly how the adopt path came to print
# the endpoint five times unguarded while the two tests for the rule both
# passed. The rule belongs to the REGION, so the check reads the whole file and
# asks a structural question instead of listing what it knows about.

setup() {
  REMOTE_SH="$BATS_TEST_DIRNAME/../scripts/remote.sh"
  [ -f "$REMOTE_SH" ]
}

# Lines that write $endpoint to the user's terminal without redacting it.
# Only output statements count: the URLs handed to curl must stay complete,
# and assignments are how the value gets built in the first place.
# Judged per OCCURRENCE, not per line. A message can redact the endpoint in one
# place and print it raw in another on the same line, and excluding any line
# that mentions the helper would wave exactly that through -- measured: adding
# a raw `$endpoint` to a line that already redacted one was not caught until
# this was rewritten. So the safe form is deleted from the line first, and
# whatever `$endpoint` survives is a leak.
scan_for_raw_endpoint() {  # $1 = file
  sed 's/\$(_remote_endpoint_display "\$endpoint")//g' "$1" \
    | grep -nE '^[[:space:]]*(echo|printf)[[:space:]]' \
    | grep -F '$endpoint' \
    || true
}

offenders() {
  scan_for_raw_endpoint "$REMOTE_SH"
}

@test "endpoint redaction: no message prints \$endpoint raw" {
  local found
  found="$(offenders)"
  if [ -n "$found" ]; then
    echo "These lines print the endpoint without _remote_endpoint_display:"
    echo "$found"
  fi
  [ -z "$found" ]
}

@test "endpoint redaction: the guard notices a leak on a line that also redacts" {
  # A guard that cannot fail is not a guard, and the failure that matters is
  # the subtle one: a message that redacts the endpoint once and prints it raw
  # as well. The first version of this check excluded any line mentioning the
  # helper and waved that straight through.
  local scratch="$BATS_TEST_TMPDIR/remote-with-leak.sh"
  cp "$REMOTE_SH" "$scratch"
  printf '%s\n' \
    '  echo "agmsg: on $(_remote_endpoint_display "$endpoint") via $endpoint" >&2' \
    >> "$scratch"

  local found
  found="$(scan_for_raw_endpoint "$scratch")"
  [ -n "$found" ]
  [[ "$found" == *"via"* ]]
}

@test "endpoint redaction: the guard notices a plainly unredacted message" {
  local scratch="$BATS_TEST_TMPDIR/remote-plain-leak.sh"
  cp "$REMOTE_SH" "$scratch"
  printf '%s\n' '  echo "agmsg: talking to $endpoint" >&2' >> "$scratch"

  local found
  found="$(scan_for_raw_endpoint "$scratch")"
  [ -n "$found" ]
  [[ "$found" == *"talking to"* ]]
}

@test "endpoint redaction: the helper drops path, query, fragment and userinfo" {
  # shellcheck source=../scripts/lib/shquote.sh
  source "$BATS_TEST_DIRNAME/../scripts/lib/shquote.sh" 2>/dev/null || true
  # Pull just the helper out of remote.sh rather than sourcing the whole
  # script, which runs its dispatcher.
  eval "$(sed -n '/^_remote_endpoint_display() {/,/^}/p' "$REMOTE_SH")"

  [ "$(_remote_endpoint_display 'https://host/t/secret')" = "https://host" ]
  [ "$(_remote_endpoint_display 'https://user:tok@host/t/secret')" = "https://host" ]
  [ "$(_remote_endpoint_display 'https://host/t/secret?q=1#frag')" = "https://host" ]
  [ "$(_remote_endpoint_display 'http://127.0.0.1:8080')" = "http://127.0.0.1:8080" ]
  # An '@' inside the path must not be read as userinfo and eat the host.
  [ "$(_remote_endpoint_display 'https://host/a@b/c')" = "https://host" ]
}
