# Remote sync — the minimum

**Status:** the design being built to. Not implemented yet.

This replaces the onboarding half of `remote-connect-onboarding.md`,
`local-first-onboarding.md`, `device-pairing.md`, and
`authentication-result-handoff.md`. Sync itself — Stage 1, read state,
retention gaps, the envelope format — is unchanged and specified elsewhere.

## What a remote is

A place to keep a team so more than one machine can use it. Nothing else.

agmsg works with no server at all. A team is created locally, used locally, and
is complete without ever connecting. Connecting is something you may do later
to a team that already exists. **The server never originates a team**, and the
identity of a local team can never depend on a service that is optional.

That single constraint decides most of what follows.

## Three things happen, and only three

**Register.** Send the team you have. The server records it and answers.

**Move.** The team's members and its message history go up. The server stores
messages as opaque blobs; `from`, `to`, `body`, and the client's timestamp are
inside the blob, and the server does not read, index, or project them.

**Continue.** From then on new messages flow as they are written.

Machine two runs the same three in reverse: it registers, pulls the team down,
and continues.

## No authentication

Reaching the server is the permission, the same way reaching the filesystem is
the permission locally. It is your server, on your network.

This is the minimum, chosen deliberately and not a placeholder we forgot to
fill. Revisit it once the whole path works end to end.

**What this removes:** per-device credentials, pairing tokens, token purposes,
the exchange→finalize two-call machine, provisional credentials, onboarding
sessions, and the credential handoff between a host and the data plane. The
two-call machine existed to deliver a secret exactly once and confirm it had
been written durably before committing. With no secret, its reason is gone.

## No required keys

`cipher: "none"` is the base, as the envelope spec already says. E2EE remains
available — the `age-v1` profile stays — but distributing keys is the
operator's own problem.

**Encryption protects you from whoever runs the server.** Self-hosting on your
own machine, that is you. It is the reason the hosted service exists, not a
property the reference server owes you.

What this removes is the machinery for making key distribution *convenient*:
the `key request` / `key approve` handshake between two of your machines.
Capability kept, convenience dropped.

## Identity is minted locally

A team gets a `team_id` and each member a `member_id`, generated **on the
machine that owns them**, once, and never regenerated. Those same ids go to the
server on connect and to the second machine on pull. One id, three places.

Today a local team is a name, and `rename.sh` rewrites every affected message
row when a name changes. That works while there is one copy. Remotely it would
mean **replaying history rewrites to every machine** — the past becomes mutable
and append-only stops holding. Hence ids.

**A team is either wholly id-bearing or wholly name-based; never partly both.**
A team created from now on gets its ids at creation, and a member joining such
a team gets one too. A team that predates ids keeps none — not even for a member
who joins it today — until it connects, at which point the team and every member
it currently has are minted together. Half a roster with ids is the one state
worth ruling out, because every reader would then need to handle both.

**Rewriting stored history happens per team, when that team connects.** Teams
that never connect keep working by name and their rows are not rewritten. On our
own store this would be one team of 5,946 messages out of 6,121 across ten teams,
and 66 distinct agent names to resolve. This is about message rows, not about the
ids above: minting an id costs nothing and touches one small file, while
rewriting history is the expensive, irreversible part that waits for a reason.

## One local team, one remote team

A `team_id` already registered is refused. This is a uniqueness constraint, not
an authorization decision.

Two teams that each have their own history never merge onto one remote — the
same reason git refuses a non-fast-forward push. A second machine is not a
second team: it arrives empty and clones.

## Deliberately out of scope

- **Anyone who can reach the server and knows a `team_id` can pull it.**
  Accepted for the minimum.
- Per-device revocation. There are no per-device credentials to revoke.
- Automated key distribution.
- Merging two populated teams.

## Removed, not deprecated

`admin team create` and the pairing-token commands are deleted. They are not a
legacy path to keep working: the model where a server operator creates a team
before a user can connect is the one this design exists to replace, and while
the command exists someone will write it into a runbook. That already happened.
