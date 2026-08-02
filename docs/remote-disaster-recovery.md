# Disaster recovery: unlocking from an authenticated bundle

This page describes `remote.sh unlock --authenticated-bundle-stdin`. It is **not**
part of onboarding, and it is not something to reach for when adding a machine.
For that, see [remote-setup.md](remote-setup.md) — adding a machine uses
`--bundle <file>` with `--confirm-digest <sha256>`, and that path is unchanged.

## Why a second entry point exists

The ordinary import gate asks a human to compare a SHA-256 over a separate live
channel — read it aloud, check it in another app — before any trust or key
material is imported. That comparison is the authority answering "did these bytes
come from the party I think they did".

**In a disaster there is nobody to compare with.** Recovery-key restore is the
route you take when the machine that held the keys is gone. The other end of the
live channel is precisely what was lost; that is why the restore is happening.
The requirement cannot be met, not because it is inconvenient, but because the
counterpart does not exist.

So this mode does not relax the gate. It **switches the authentication authority**
from a live human digest comparison to an upstream AEAD verifier that already ran
over exactly these bytes — in practice, a recovery-vault client that opened the
bundle with a key derived from the recovery key, under an authenticated cipher
whose additional data binds the expected team and vault.

## What remote.sh does and does not guarantee

`remote.sh` still verifies the snapshot chain: the bundle has to be internally
consistent and agree with the epoch history it claims.

**`remote.sh` does not authenticate the input in this mode, and cannot.** It has
no access to the recovery key or the derived key, so it cannot check that any
verifier ran at all. It accepts the caller's assertion. That is a trust
delegation, and it is stated here rather than hidden: the guarantee is only as
good as the program on the other side of the pipe.

Use it only from a program that holds such an authenticator and binds the
expected team and context. If you are typing this flag by hand, you are using the
wrong mode.

## Why stdin and not a file path

The bytes are read from stdin, not from a path, and that is deliberate. A
pathname is not the bytes: if the caller authenticated a file and then handed
over its name, anything with write access could substitute different content
between the authentication and the import. Passing the exact buffer through the
pipe closes that window — what was authenticated and what is imported are the
same bytes, read once.

A side effect worth having: the decrypted bundle never has to exist as a
plaintext file on disk.

## Contract

- `--bundle <file>` **requires** `--confirm-digest <sha256>`. Unchanged.
- `--authenticated-bundle-stdin` **replaces** that pair. Combining it with
  `--bundle`, `--confirm-digest`, `--snapshot`, or `--identity` is an error, not a
  precedence rule — two authorities disagreeing about which bytes were
  authenticated must not resolve silently.
- Empty or truncated input fails closed. Nothing is imported.
- The courier `fetch` path uses the digest mode and must not use this one: age
  encryption to a recipient is not sender-authenticated, so a server that knows
  the recipient's public key could seal a substitute. There the live-channel
  comparison is load-bearing.
