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

# Accepted by the per-sync check for an already-connected team?
#
# Driven through connectedBinding(), which is what continued sync calls — not
# through the rule function it uses. Calling the helper directly would leave the
# call site unbound: reverting connectedBinding to its old inline loopback list
# keeps the helper correct and every such test green, while continued sync goes
# back to refusing LAN addresses. That is precisely the "pull works, sync dies"
# failure this change exists to prevent (found by review, not by me).
js_ok() {
  AGMSG_TEST_URL="$1" node --input-type=module -e "
    import { connectedBinding } from '$SCRIPTS/internal/remote-sync.mjs';
    const endpoint = process.env.AGMSG_TEST_URL;
    const value = {
      name: 'demo',
      remote_binding: {
        endpoint,
        server_instance_id: '018f3f7e-0000-7000-8000-000000000000',
        remote_team_id: '018f3f7e-0000-7000-8000-000000000001',
        protocol_version: 1,
        connected_at: '2026-07-20T13:00:00.000Z',
        disconnected_at: null,
        capabilities: { write_allowed_ciphers: ['none'] },
      },
    };
    try { connectedBinding(value, 'demo'); process.exit(0); }
    catch { process.exit(1); }
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

@test "endpoint: the two implementations agree, without consulting the table (#717)" {
  # The exhaustive cases live in tests/fixtures/endpoint-verdicts.jsonl and are
  # run against both implementations by the two table harnesses. This is not a
  # smaller copy of that: the table asks "does each side match the expected
  # verdict", and this asks "do the two sides match EACH OTHER". A wrong row in
  # the table makes both harnesses fail in the same direction and reads like a
  # code defect; this one keeps working, because it has no expectation to be
  # wrong about.
  #
  # One case per direction is enough for that job — coverage is the table's.
  both "http://192.168.191.205:8787" allow
  both "http://127.0.0.1:8787" allow
  both "http://8.8.8.8:8787" deny
  both "http://127.0.0.1.evil.com" deny
}

@test "endpoint: the userinfo trick is still refused (#717)" {
  # `http://localhost@evil.com` parses with host evil.com. The validator rejects
  # userinfo outright rather than relying on the host check behind it, and the
  # message says which part was the problem — neither of which a verdict column
  # can express.
  run python3 "$SCRIPTS/internal/validate-endpoint.py" "http://localhost@evil.com"
  [ "$status" -ne 0 ]
  grep -qF 'userinfo' <<<"$output"
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

@test "endpoint: the refusal names the zone, and the list names what is allowed (#717)" {
  # Two gaps found by the seat building the table, and the second is the
  # quieter one. Someone who wrote a zone index HAS given a private address —
  # answering them with "use a private IP" is a dead end, so the zone gets its
  # own message naming the part that is wrong and a form that works.
  run python3 "$SCRIPTS/internal/validate-endpoint.py" "http://[fe80::1%eth0]:8787"
  [ "$status" -ne 0 ]
  grep -qF 'zone index' <<<"$output"
  grep -qF 'fe80::1' <<<"$output"

  # And the general refusal lists fe80::/10, which is accepted. Allowing
  # something without saying so is worse than the dead end: nobody hits an
  # error, so nobody reports that link-local works.
  run python3 "$SCRIPTS/internal/validate-endpoint.py" "http://example.com:8787"
  [ "$status" -ne 0 ]
  grep -qF 'fe80::/10' <<<"$output"

  # The claim above is only worth anything if it is true.
  run python3 "$SCRIPTS/internal/validate-endpoint.py" "http://[fe80::1]:8787"
  [ "$status" -eq 0 ]
}
