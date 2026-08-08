#!/usr/bin/env bats

# The remote-setup walkthrough now offers the Compose path (#665), and points
# at `server/compose.yaml` for its values instead of restating them.
#
# The contract is narrower than "no compose value appears here", and the
# difference is the point (review):
#
#   credentials and database settings   NOT duplicated. Two copies of a
#                                       password disagree eventually, and the
#                                       copy in the walkthrough is the one
#                                       someone pastes.
#   the published port                  IS written. A reader needs it to run
#                                       the health check, so hiding it behind
#                                       a link would be worse. It is pinned
#                                       against compose.yaml instead.
#
# Both are derived FROM compose.yaml rather than listed here: after the
# password or the port changes, these still hold, which a literal would not.
#
# The cross-file links are checked by resolving them, because a walkthrough
# that sends you to another file is only as good as the anchor it names.

DOC="${BATS_TEST_DIRNAME}/../docs/remote-setup.md"
COMPOSE="${BATS_TEST_DIRNAME}/../server/compose.yaml"
SERVER_README="${BATS_TEST_DIRNAME}/../server/README.md"

# An environment value out of compose.yaml, by key.
compose_value() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$COMPOSE" | head -1
}

# GitHub's heading anchor: lowercase, spaces to hyphens, punctuation dropped.
slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '-' \
    | tr -cd 'a-z0-9-'
}

@test "remote-setup: the walkthrough offers the Compose path" {
  grep -q 'docker compose up -d --build' "$DOC"
  # And still reaches the health check, which is what tells you it worked.
  grep -q '/v1/health' "$DOC"
}

@test "remote-setup: compose.yaml's password is not restated in the doc" {
  password="$(compose_value POSTGRES_PASSWORD)"
  # A positive control. If compose.yaml is restructured so the key stops
  # parsing, an empty needle would match every file and this would pass while
  # checking nothing.
  [ -n "$password" ]
  run grep -F -q -- "$password" "$DOC"
  [ "$status" -ne 0 ]
}

@test "remote-setup: the localhost health check uses compose's published port" {
  # The one compose value the doc DOES carry, kept in sync rather than trusted.
  # Published as "<host>:<container>"; the host side is what a reader curls.
  port="$(sed -n 's/^[[:space:]]*-[[:space:]]*"\([0-9][0-9]*\):[0-9][0-9]*"[[:space:]]*$/\1/p' "$COMPOSE" | head -1)"
  [ -n "$port" ]

  # Every localhost URL in the doc, derived rather than the one I remembered
  # to look at: a second one added later with the old port is exactly the
  # drift this exists for.
  used="$(grep -o 'http://127\.0\.0\.1:[0-9]*' "$DOC" | sed 's|.*:||' | sort -u)"
  [ -n "$used" ]
  [ "$used" = "$port" ]
}

@test "remote-setup: no connection string is spelled out in the doc" {
  # The from-source path moved to server/README.md rather than being copied.
  # A `postgresql://` line here means the copy came back.
  run grep -q 'postgresql://' "$DOC"
  [ "$status" -ne 0 ]
}

@test "remote-setup: every link into server/README.md resolves to a heading" {
  # Extract the anchors this doc points at, rather than checking the ones
  # someone remembered to list.
  anchors="$(grep -o '(\.\./server/README\.md#[a-z0-9-]*)' "$DOC" \
    | sed 's|(\.\./server/README\.md#||; s|)||' | sort -u)"
  [ -n "$anchors" ]

  headings=""
  while IFS= read -r line; do
    case "$line" in
      '#'*) headings="${headings}$(slug "${line#\#\# }")
" ;;
    esac
  done < "$SERVER_README"

  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%s' "$headings" | grep -q -x -- "$a" || {
      echo "docs/remote-setup.md points at server/README.md#$a, which is not a heading there" >&2
      echo "headings found: $headings" >&2
      return 1
    }
  done <<EOF
$anchors
EOF
}

@test "remote-setup: editing the guarded doc does not skip this suite" {
  # Everything above is decoration if the suite does not run on the change it
  # is watching for. The `changes` job maps `docs/*` to docs_only=true, which
  # skips every bats shard, so this file has to be pulled out of that arm —
  # the same reason SKILL.md is. Pinned here rather than trusted, because the
  # line is one `case` arm and removing it fails nothing else.
  # The workflow's own `case` is lifted out and RUN, rather than checked for a
  # line in the right order: order is only one of the ways this arm can stop
  # working, and the classifier is what actually decides.
  workflow="${BATS_TEST_DIRNAME}/../.github/workflows/tests.yml"
  block="$(awk '/case ".f" in/,/^ *esac$/' "$workflow")"
  # Positive control: an empty block would leave docs_only at whatever it was
  # initialised to, and every case below would agree with itself.
  [ -n "$block" ]

  # `run bash -c`, not a `$( )` around the eval: bash 3.2 — which is what CI's
  # macOS runner has — cannot parse a `case` inside command substitution.
  classify='f="$1"; docs_only=true; app_changed=false; server_changed=false; sync_changed=false; eval "$2"; echo "$docs_only"'

  run bash -c "$classify" _ docs/remote-setup.md "$block"
  [ "$status" -eq 0 ]
  [ "$output" = false ]

  # The arm is specific, not a hole punched through the whole docs tree.
  run bash -c "$classify" _ docs/spec/v1.md "$block"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}

@test "remote-setup: the network boundary it links to is in this doc" {
  # The walkthrough recommends a stack that publishes a port and ships a
  # development password. The warning used to live only in server/README.md,
  # which is not where someone standing up a server is reading.
  grep -q '^### Network boundary' "$DOC"
  grep -q '(#network-boundary)' "$DOC"
}
