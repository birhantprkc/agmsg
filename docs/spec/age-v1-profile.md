# agmsg `age-v1` cipher profile

**Status:** proposed (dogfood profile)
**Profile identifier:** `age-v1`
**Envelope version:** `1`

This document pins the first encrypted envelope profile for the agmsg remote
sync protocol. It extends the opaque envelope in
[`server/spec/v1.md`](../../server/spec/v1.md) without changing the HTTP message
schema or the Stage-1 storage-driver durability boundary.

`age-v1` is a standard binary [age v1 file][age-format], encrypted to native
X25519 age recipients. It deliberately does not define another AEAD layer or a
private age-file variant. This keeps recovery, debugging, and independent audit
possible with the standard `age` CLI and conforming age libraries.

The term **authenticated binding context** is used throughout this profile.
Age's STREAM payload construction provides ciphertext integrity. After
successful age decryption, the reader compares the authenticated plaintext
context with independently trusted envelope and stream metadata. This is not an
age API for external AEAD additional authenticated data, and this profile MUST
NOT describe it as such.

## Fixed identifier and compatibility rule

The meaning of `age-v1` is immutable. An implementation MUST NOT change its
recipient type, binary age-file requirement, plaintext framing, context fields,
canonical encodings, comparison rules, or failure classifications while using
this identifier. An incompatible change requires a new identifier, beginning
with `age-v2`.

Readers either implement this document exactly or treat `age-v1` as
`unsupported_cipher`. There is no profile-content negotiation under the
`age-v1` identifier.

## Outer envelope

An `age-v1` envelope has:

```json
{
  "v": 1,
  "cipher": "age-v1",
  "key_id": "epoch-2026-07-01",
  "blob": "YWdlLWVuY3J5cHRpb24ub3JnL3YxLi4u"
}
```

- `v` MUST be the JSON integer `1`.
- `cipher` MUST be the exact ASCII string `age-v1`.
- `key_id` MUST be a non-null string satisfying the HTTP v1 envelope rules. In
  addition, this profile restricts it to 1–64 ASCII bytes matching
  `[a-z0-9][a-z0-9._-]{0,63}`. It names one immutable recipient-set epoch within
  one stream binding.
- `blob` MUST be canonical padded RFC 4648 base64 of one complete, unarmored,
  binary age v1 file. ASCII armor, concatenated age files, trailing bytes,
  compression, and profile-level padding are forbidden.
- The age header MUST contain one or more native X25519 recipient stanzas and
  no other recipient stanza type. Scrypt/passphrase recipients, plugins, SSH
  recipients, and hybrid stanza sets are not part of `age-v1`.

The decoded age file must fit the smaller of the HTTP protocol blob limit and
the authenticated `max_blob_bytes` capability. The server validates only the
outer envelope and continues to treat the decoded age file as opaque.

## Recipient-set epochs

A `key_id` identifies an immutable set of X25519 recipients and its private
identity material. Changing the recipient set, rotating any identity, or
reusing the label with different key material requires a new `key_id`. A
recipient-set manifest MUST bind the remote `server_instance_id`, `team_id`,
`key_id`, recipient list, and profile identifier and MUST be distributed over
an authenticated out-of-band channel. The server never receives private
identities. A writer MUST encrypt each new envelope to every recipient in the
selected immutable manifest and to no recipient outside it.

Each client binding maintains an append-only, sequence-effective key-epoch
history alongside the local security history. Each entry contains a local
epoch revision, `effective_from_seq`, `cipher`, and `key_id`. The first entry is
effective from sequence `1`. A prospective rotation uses an authenticated
capability snapshot's `next_sequence_boundary`, and a message at sequence `S`
uses the greatest revision whose `effective_from_seq <= S`. Same-boundary
changes collapse to the greatest revision. Clients MUST bound this history to
4096 effective entries and import established history when provisioning a new
device; they MUST NOT infer old epochs from the current key alone.

Before creating an encrypted envelope, the writer MUST verify that `age-v1` is
allowed by both the effective server write policy and effective local minimum,
and MUST select the `key_id` effective at the prospective sequence boundary.
On pull, an otherwise valid `age-v1` envelope with a `key_id` different from
the locally pinned epoch at its `server_seq` is a durable `policy_violation`.
It MUST NOT be trial-decrypted, projected, displayed, or marked read.

Rotation and revocation are prospective. Removing a recipient from a later
epoch does not revoke its ability to decrypt ciphertext from an earlier epoch.
Readers SHOULD retain authorized old identities while old messages or durable
quarantine may require them. A missing identity for the expected epoch produces
`pending_key`, not a fallback to `none` or another key.

## Plaintext frame

Age encrypts exactly one binary plaintext frame. Integers are unsigned,
big-endian, and use the widths shown below. Lengths count bytes, not Unicode
scalar values. No field may be omitted and no trailing byte is allowed.

```text
offset  width       value
0       16          magic = 61 67 6d 73 67 2d 61 67 65 2d 76 31 00 00 00 00
16      4           context_length (u32)
20      variable    canonical authenticated binding context
...     4           message_length (u32)
...     variable    canonical message bytes
```

The 16-byte magic is ASCII `agmsg-age-v1` followed by four zero bytes.
`context_length` MUST equal the exact encoded context length.
`message_length` MUST equal the exact canonical-message length. The frame ends
immediately after the message bytes.

### Canonical authenticated binding context

The context fields occur once, in this exact order:

```text
width       value
4           protocol_version (u32, MUST equal 1)
16          team_id (RFC 9562 UUID bytes in network order)
16          wire_id (RFC 9562 UUID bytes in network order)
2           cipher_length (u16, MUST equal 6)
6           cipher UTF-8 bytes (ASCII `age-v1`)
2           key_id_length (u16, 1..64)
variable    key_id ASCII bytes
```

`team_id` is the stable remote team/stream ID from the verified HTTP binding,
not a mutable team name or local path. `wire_id` is the outer remote message
UUIDv4, not the local driver UUID. `key_id` and `cipher` are the exact outer
envelope values. The protocol version is the URL/envelope protocol version,
not an age implementation version.

For example, the context length for `key_id = "epoch-1"` is
`4 + 16 + 16 + 2 + 6 + 2 + 7 = 53` bytes.

### Canonical message bytes

The message bytes MUST be RFC 8785 JCS encoding of exactly the same four-field
plaintext object defined for `cipher: "none"` in the HTTP v1 specification:

```json
{"body":"Run the test suite","created_at":"2026-07-20T06:30:00.000000Z","from_agent":"leader","to_agent":"worker-1"}
```

All `none` plaintext validation rules still apply before encryption and after
decryption. The complete framed plaintext and resulting binary age file must
fit the authenticated server limit. Writers MUST check the final encrypted age
file size before durably reserving the envelope.

## Seal and durable retry

The writer performs these steps in order:

1. Generate and durably reserve the random wire UUIDv4.
2. Select the effective `key_id` and exact recipient-set manifest.
3. Construct the canonical context and canonical message bytes.
4. Encrypt the complete frame once as a binary age v1 file.
5. Base64-encode the complete age file canonically and durably commit the exact
   wire ID and outer envelope before exposing them to the HTTP engine.

The Stage-1 H1 rule is absolute: every retry, reconciliation attempt, crash
recovery, export, and compaction replay for that wire ID MUST reuse the exact
`v`, `cipher`, `key_id`, and `blob`. A client MUST NOT re-encrypt or re-encode
the same wire ID, even to the same recipients.

## Open, binding verification, and failure states

The reader evaluates server policy, local security history, and key-epoch
history before decryption. If policy permits processing and the expected
identity is available, it decrypts the single age file and then:

1. parses the complete frame with overflow-safe length checks;
2. independently reconstructs the expected canonical context from the verified
   `(protocol_version, team_id)`, outer wire ID, outer cipher, and outer
   `key_id`;
3. checks exact context length and compares the complete received context with
   the expected context in constant time;
4. only after a successful comparison, parses and validates the JCS message.

The comparison MUST cover every context byte and MUST NOT stop at the first
difference. After separately requiring equal public lengths, an implementation
MUST use a constant-time equality primitive directly over the two complete
context byte strings. Comparing only hashes, individual fields, or a prefix is
insufficient. Implementations MUST NOT project any message field before this
comparison succeeds.

Failures map to the Stage-1 durable quarantine layer as follows:

| Condition | Durable state |
|---|---|
| Effective policy rejects `age-v1` or the sequence-effective `key_id` differs | `policy_violation` |
| Expected identity is not installed | `pending_key` |
| Age decryption fails with the selected identity | `authentication_failed` |
| Frame/context is truncated, reordered, duplicated, has trailing bytes, or differs from trusted binding metadata | `authentication_failed` |
| Context matches, but the canonical message is invalid | `malformed` |
| Cipher profile is not implemented | `unsupported_cipher` |

`authentication_failed` MUST remain durable for operator inspection and later
reprocessing. It MUST NOT fall back to another identity, `none`, partial
display, local import, or read-state advancement. The transport cursor may
advance only after that blocking outcome is durably quarantined, as specified
by the HTTP v1 three-layer state model.

## Key bootstrap and operational limits

- Recipient public keys, private identities, recipient-set manifests, and epoch
  history are provisioned outside the message server over an authenticated
  channel. Copying only the current private key is insufficient for history.
- A headless sync process MUST use explicit identity files or an equivalent
  non-interactive secret provider. Interactive passphrases and trial-decrypting
  every installed key are forbidden.
- Identity files MUST be kept outside remote storage, excluded from logs and
  subprocess argument lists, and protected with platform-appropriate file
  permissions. HTTP bearer credentials and age identities are separate secrets.
- The profile does not define padding. Team relationship, key epoch, age-file
  length, server arrival time, traffic frequency, and sequence remain visible.
- Because the server cannot read the plaintext, routing, search, and wake remain
  team-wide; recipient projection happens locally after verified decryption.

## Shared conformance vectors

[`age-v1-vectors.json`](vectors/age-v1-vectors.json) is normative test material
for client, driver, and hosted-server integration suites. Its identities are
public test secrets and MUST NEVER be used outside tests. A conforming reader
must cover at least:

1. successful decryption and exact context/message recovery;
2. decryption with the wrong team's identity;
3. outer wire-ID substitution with otherwise unchanged ciphertext;
4. an authenticated plaintext with a truncated context;
5. an authenticated plaintext with reordered context fields.

The four negative cases MUST produce `authentication_failed` and MUST NOT yield
a projection. In the manifest, `envelope_from` means reuse the named vector's
envelope byte-for-byte, `binding_override` changes only the independently
trusted expected binding, and `identity` selects the named public test
identity. The manifest records exact expected states so every implementation
consumes the same attacks.

[age-format]: https://age-encryption.org/v1
