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
# Three things this has to survive, each one having already slipped past a
# version of it:
#
#   1. Per OCCURRENCE, not per line. A message can redact the endpoint once and
#      print it raw as well; excluding every line that mentions the helper
#      waves exactly that through.
#   2. Both spellings. `${endpoint}` is the same expansion as `$endpoint` and a
#      fixed-string search for the second does not see the first.
#   3. Continuations. `echo "..." \` + `"$endpoint"` puts the leak on a
#      different physical line from the word `echo`.
#
# So: join continuations first, then delete the safe form, then look for any
# surviving expansion of the name on a line that writes output.
scan_for_raw_endpoint() {  # $1 = file
  sed -e :a -e '/\\$/N; s/\\\n//; ta' "$1" \
    | sed -E 's/\$\(_remote_endpoint_display "\$\{?endpoint\}?"\)//g' \
    | grep -nE '(^|[[:space:]]|;|&&|\|\|)(echo|printf)[[:space:]]' \
    | grep -E '\$\{?endpoint\}?' \
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

@test "endpoint redaction: the guard notices the braced spelling" {
  # ${endpoint} is the same expansion. A fixed-string search for $endpoint
  # does not see it, and the leak is identical.
  local scratch="$BATS_TEST_TMPDIR/remote-braced-leak.sh"
  cp "$REMOTE_SH" "$scratch"
  printf '%s\n' '  echo "agmsg: braced ${endpoint}" >&2' >> "$scratch"

  local found
  found="$(scan_for_raw_endpoint "$scratch")"
  [ -n "$found" ]
  [[ "$found" == *"braced"* ]]
}

@test "endpoint redaction: the guard notices a leak on a continuation line" {
  # The word `echo` and the leak are on different physical lines, so a check
  # that looks at one line at a time sees an echo with no endpoint, then an
  # endpoint with no echo, and reports neither.
  local scratch="$BATS_TEST_TMPDIR/remote-continued-leak.sh"
  cp "$REMOTE_SH" "$scratch"
  printf '%s\n' '  echo "agmsg: continued" \' '    "$endpoint" >&2' >> "$scratch"

  local found
  found="$(scan_for_raw_endpoint "$scratch")"
  [ -n "$found" ]
  [[ "$found" == *"continued"* ]]
}

@test "endpoint redaction: the guard does not fire on the redacted form" {
  # The other half of a usable guard: it must stay quiet on correct code, in
  # both spellings, or the fix for a false negative becomes a false positive.
  local scratch="$BATS_TEST_TMPDIR/remote-clean.sh"
  cp "$REMOTE_SH" "$scratch"
  printf '%s\n' \
    '  echo "agmsg: on $(_remote_endpoint_display "$endpoint")" >&2' \
    '  echo "agmsg: on $(_remote_endpoint_display "${endpoint}")" >&2' \
    >> "$scratch"

  [ -z "$(scan_for_raw_endpoint "$scratch")" ]
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
