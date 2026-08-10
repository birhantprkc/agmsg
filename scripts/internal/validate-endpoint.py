#!/usr/bin/env python3
"""Strictly validate a --endpoint value (remote-connect review finding R2).

A naive shell glob/prefix check (`case $endpoint in http://127.0.0.1*)`)
is bypassable: `http://127.0.0.1.evil.com`, `http://localhost.evil.com`,
and `http://localhost@evil.com` (userinfo trick — the real host is
evil.com) all match a bare string-prefix test while actually pointing
somewhere else. This does real structural URL parsing instead.

WHY http IS ALLOWED FOR IP LITERALS BUT NOT FOR NAMES
-----------------------------------------------------
The attack the strict parsing exists to stop is a NAME that looks like a
safe host: `127.0.0.1.evil.com` reads like loopback and resolves wherever
its owner points it. That attack needs a name. An IP literal has no such
gap — what is written in the URL is the address the connection goes to,
with nothing in between to reinterpret it. So the rule is not "loopback
is special", it is:

    http  is allowed when the host is an IP LITERAL in a private range
    names are https-only, with `localhost` kept as the one exception

which is why a LAN address works and `http://192.168.1.10.evil.com` does
not. Two machines on a network you control, talking over http, is an
ordinary thing to do and does not need a tunnel to a loopback port.

Keep that reasoning here. A rule with no reason attached gets deleted by
the next person who finds it inconvenient — which is how this ended up
refusing LAN addresses in the first place.

Exits 0 (silent) if <endpoint> (argv[1]) is acceptable; exits 1 with a
one-line reason on stderr otherwise.
"""
import ipaddress
import sys
from urllib.parse import urlsplit

# Written out rather than using ipaddress.is_private, so the accepted set is
# the one stated here and does not move when the interpreter's definition of
# "private" changes underneath it.
PRIVATE_NETS = [
    ipaddress.ip_network("127.0.0.0/8"),      # loopback
    ipaddress.ip_network("10.0.0.0/8"),       # RFC1918
    ipaddress.ip_network("172.16.0.0/12"),    # RFC1918
    ipaddress.ip_network("192.168.0.0/16"),   # RFC1918
    ipaddress.ip_network("169.254.0.0/16"),   # link-local
    ipaddress.ip_network("::1/128"),          # loopback
    ipaddress.ip_network("fc00::/7"),         # unique local
    ipaddress.ip_network("fe80::/10"),        # link-local
]

# The one name that stays: it is resolved by the host's own resolver to a
# loopback address by universal convention, and every self-host walkthrough
# starts with it.
ALLOWED_HTTP_NAMES = {"localhost"}


def fail(msg):
    print(f"agmsg: {msg}", file=sys.stderr)
    sys.exit(1)


def private_ip_literal(host):
    """True when <host> is an IP literal inside one of PRIVATE_NETS.

    A hostname never parses here, which is the point: this is what separates
    "the address is written in the URL" from "a name resolves to whatever its
    owner decides".
    """
    # A zone index (`fe80::1%eth0`) names an INTERFACE on the machine reading
    # the URL, not part of the address. ipaddress accepts it and the Node side's
    # parser does not, so the two disagreed on it (found while building the
    # shared table). Refused on both rather than accepted on both: an endpoint
    # is stored and later re-read by whatever process syncs next, and a scope
    # that only means something on one host is not a thing to persist in a
    # binding. Nothing needs it — a server reachable over a link-local address
    # with an explicit zone is not the case this rule was widened for.
    if "%" in host:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return any(ip in net for net in PRIVATE_NETS)


def main():
    if len(sys.argv) != 2:
        fail("internal error: validate-endpoint.py needs exactly one argument")
        return
    endpoint = sys.argv[1]

    try:
        parts = urlsplit(endpoint)
    except Exception:
        fail("--endpoint could not be parsed as a URL")
        return

    if parts.scheme == "https":
        if not parts.hostname:
            fail("--endpoint has no host")
        return

    if parts.scheme == "http":
        if parts.username is not None or parts.password is not None:
            fail("--endpoint must not contain userinfo (user@ or user:pass@)")
        host = parts.hostname or ""
        if host in ALLOWED_HTTP_NAMES or private_ip_literal(host):
            return
        # What this costs, stated accurately. The old wording said a
        # "token/credential" would be sent unencrypted; the client sends no
        # Authorization header at all, so that was not the risk. The risk is
        # the message bodies: on a team synced with cipher `none` the envelope
        # contents cross the network in the clear.
        fail(
            "--endpoint must be https://, or http:// to a private IP address "
            "(10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, ::1, fc00::/7). "
            "Over plaintext http the message bodies of a team synced without "
            "encryption cross the network in the clear. Either use https://, "
            "or give the LAN IP of the server instead of a name "
            "(http://192.168.1.10:8787), or connect with --e2ee so the "
            "contents are sealed before they leave this machine."
        )
        return

    fail("--endpoint must start with https:// (or http:// to a private IP address)")


if __name__ == "__main__":
    main()
