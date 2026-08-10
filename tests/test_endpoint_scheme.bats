#!/usr/bin/env bats

# Which endpoints may be spoken to over plaintext http.
#
# The rule is "IP literal in a private range", not "loopback". The strict URL
# parsing exists to stop a NAME dressed as a safe host — `127.0.0.1.evil.com`
# reads like loopback and resolves wherever its owner points it. A literal has
# no such gap: what is written is where the connection goes. So names stay
# https-only (`localhost` excepted) and a LAN address over http is allowed.
#
# TWO implementations decide this, and a rule that holds in only one of them is
# worse than no rule: connect and pull go through validate-endpoint.py, every
# later sync of an already-connected team goes through remote-sync.mjs. Enforce
# it in the first only and a team connects happily and then dies on its next
# sync. So every case below is asserted against BOTH.

load test_helper

# Both checks are pure functions of the URL — no store, no team, no state — so
# they are exercised against the repository's own scripts rather than a built
# test environment. Nothing here writes anything.
setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
}

# Accepted by the connect/pull validator?
py_ok() {
  python3 "$SCRIPTS/internal/validate-endpoint.py" "$1" 2>/dev/null
}

# Accepted by the per-sync check for an already-connected team? Takes a URL and
# reduces it to the same question the module asks: the hostname as `new URL`
# reports it (IPv6 stays bracketed there, which is exactly the shape the module
# has to cope with).
js_ok() {
  # The URL travels in the environment, not in argv: with `node -e` the user
  # arguments do not land where a script's would, and the first attempt at this
  # helper had node trying to import the URL as a module. It failed loudly, but
  # a version that failed quietly would have made every case read "deny".
  AGMSG_TEST_URL="$1" node --input-type=module -e "
    import { allowsPlaintext } from '$SCRIPTS/internal/remote-sync.mjs';
    const u = new URL(process.env.AGMSG_TEST_URL);
    process.exit(u.protocol === 'https:' || allowsPlaintext(u.hostname) ? 0 : 1);
  "
}

# Assert both implementations agree with the expectation AND with each other.
both() {
  local url="$1" want="$2"
  if py_ok "$url"; then local py=allow; else local py=deny; fi
  if js_ok "$url"; then local js=allow; else local js=deny; fi
  [ "$py" = "$want" ] || { echo "validator: $url -> $py, wanted $want"; return 1; }
  [ "$js" = "$want" ] || { echo "sync check: $url -> $js, wanted $want"; return 1; }
}

@test "endpoint: a LAN address over http is allowed, without a tunnel (#717)" {
  # The case this change exists for: another machine on the same network,
  # named by its address, no port-forward in between.
  both "http://192.168.191.205:8787" allow
  both "http://10.1.2.3:8787" allow
  both "http://172.16.0.9:8787" allow
  both "http://172.31.255.254:8787" allow
  both "http://169.254.10.1:8787" allow
  both "http://[fd00::1]:8787" allow
  both "http://[fe80::1]:8787" allow
}

@test "endpoint: loopback keeps working (#717)" {
  both "http://127.0.0.1:8787" allow
  both "http://127.1.2.3:8787" allow
  both "http://localhost:8787" allow
  both "http://[::1]:8787" allow
}

@test "endpoint: a public address over http is still refused (#717)" {
  # The other direction. Without this, "it got wider" and "it got wider than
  # intended" look the same.
  both "http://8.8.8.8:8787" deny
  both "http://172.32.0.1:8787" deny     # just outside 172.16/12
  both "http://172.15.255.255:8787" deny # just below it
  both "http://192.169.0.1:8787" deny    # neighbour of 192.168/16
  both "http://[2001:db8::1]:8787" deny
}

@test "endpoint: a NAME over http is still refused, however it is spelled (#717)" {
  # The attack the strict parsing was written for, and the reason names are
  # treated differently from literals: each of these reads like a safe host and
  # resolves wherever its owner decides.
  both "http://127.0.0.1.evil.com" deny
  both "http://localhost.evil.com" deny
  both "http://192.168.1.10.evil.com" deny
  both "http://example.com:8787" deny
}

@test "endpoint: the userinfo trick is still refused (#717)" {
  # `http://localhost@evil.com` parses with host evil.com. The validator rejects
  # userinfo outright rather than relying on the host check behind it.
  run python3 "$SCRIPTS/internal/validate-endpoint.py" "http://localhost@evil.com"
  [ "$status" -ne 0 ]
  [[ "$output" == *"userinfo"* ]]
}

@test "endpoint: https is unaffected by any of this (#717)" {
  both "https://example.com" allow
  both "https://192.168.1.10:8787" allow
}

@test "endpoint: the refusal says what to do instead, and says why truthfully (#717)" {
  run python3 "$SCRIPTS/internal/validate-endpoint.py" "http://example.com:8787"
  [ "$status" -ne 0 ]
  # Plain commands and `refute`, not `[[ ]]`: a non-last `[[ ]]` cannot fail a
  # test on bash 3.2, which is what CI's macOS legs run (#670, #716). Every one
  # of these is non-last, so as `[[ ]]` they would have asserted nothing there.
  #
  # The old message blamed a "token/credential" being sent unencrypted. The
  # client sends no Authorization header at all, so that was never the risk;
  # the risk is the message bodies of a team synced without encryption.
  refute grep -qF 'credential' <<<"$output"
  grep -qF 'message bodies' <<<"$output"
  # And a refusal that does not say what to do instead leaves the operator to
  # find a tunnel on their own, which is what happened.
  grep -qF 'https://' <<<"$output"
  grep -qF 'LAN IP' <<<"$output"
  grep -qF -- '--e2ee' <<<"$output"
}
