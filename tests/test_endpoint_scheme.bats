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

@test "endpoint: the IPv6 ranges are numeric, not a spelling (#717)" {
  # Found by review. The first version compared the leading characters of the
  # hostname, so `fc::1` — whose first group is 0x00fc, nowhere near fc00::/7 —
  # read like a unique-local address and was allowed. Node hands the short form
  # through unchanged, so the misreading survives all the way in.
  both "http://[fc::1]:8787" deny
  both "http://[fe8::1]:8787" deny
  # The boundaries themselves, on both sides of each edge.
  both "http://[fbff::1]:8787" deny
  both "http://[fc00::1]:8787" allow
  both "http://[fdff::1]:8787" allow
  both "http://[fe00::1]:8787" deny
  both "http://[fe7f::1]:8787" deny
  both "http://[fe80::1]:8787" allow
  both "http://[febf::1]:8787" allow
  both "http://[fec0::1]:8787" deny
}

@test "endpoint: a form that has to be decoded first is not an IP literal (#717)" {
  # Also found by review, and it is the premise of the whole rule that was at
  # stake: "what is written in the URL is where the connection goes". Node
  # rewrites decimal, hex and zero-padded octal into dotted quads, so a check on
  # the PARSED host accepts spellings no reader would recognise as an address —
  # and the Python side, which has no such normalisation, refused them. The two
  # disagreed on five inputs before this; now both read the raw text.
  both "http://2130706433/" deny
  both "http://0x7f000001/" deny
  both "http://0177.0.0.1/" deny
  both "http://192.168.1.1./" deny
  both "http://[::ffff:192.168.1.1]:8787" deny
  # userinfo, refused on both sides rather than left to the host check behind it
  both "http://evil.com@192.168.1.1/" deny
}

@test "endpoint: an octet with a leading zero is not an address as written (#717)" {
  # Found in review. `\d{1,3}` accepted `01` and Number() read it as 1, so
  # `192.168.01.1` passed the Node side and was refused by the Python side,
  # which rejects leading zeros outright. A leading zero is also how the octal
  # forms are spelled, and the rule is that the address is readable as written.
  both "http://192.168.01.1:8787" deny
  both "http://010.0.0.1:8787" deny
  both "http://192.168.1.01:8787" deny
  # The zero octet itself is still an ordinary address.
  both "http://10.0.0.1:8787" allow
  both "http://192.168.0.1:8787" allow
}
