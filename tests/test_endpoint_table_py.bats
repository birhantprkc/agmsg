#!/usr/bin/env bats

# The connect/pull validator, driven from the shared endpoint table.
#
# Which endpoints may be spoken to over plaintext http is decided by TWO
# implementations: validate-endpoint.py on connect and pull, remote-sync.mjs on
# every later sync of an already-connected team. A rule that holds in only one
# of them is worse than no rule — a team connects happily and then dies on its
# next sync (#717).
#
# So the cases live in ONE file, tests/fixtures/endpoint-verdicts.jsonl, and
# this harness and tests/test_endpoint_table_node.bats each read that same file.
# A row added here is a row the other side must answer too. Writing the cases
# out twice is how the two drifted apart in the first place.
#
# The table is the specification. When a row is wrong, change the row — do not
# add an exception in one implementation.

load test_helper

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  # Overridable so the positive control can point at a copy with an extra row.
  TABLE="${AGMSG_ENDPOINT_TABLE:-$BATS_TEST_DIRNAME/fixtures/endpoint-verdicts.jsonl}"
}

# endpoint<TAB>verdict, one row per line. Fails loudly rather than emitting a
# short list: a table that silently loses rows reads exactly like a table whose
# rows all pass.
table_rows() {
  python3 - "$TABLE" <<'PY'
import json, sys
path = sys.argv[1]
rows = 0
with open(path, encoding="utf-8") as fh:
    for n, line in enumerate(fh, 1):
        if not line.strip():
            continue
        row = json.loads(line)
        ep, verdict = row["endpoint"], row["verdict"]
        if verdict not in ("allow", "deny"):
            sys.exit(f"{path}:{n}: verdict must be allow or deny, got {verdict!r}")
        if "\t" in ep or "\n" in ep:
            sys.exit(f"{path}:{n}: endpoint contains a tab or newline; the "
                     f"harness passes rows as TSV and cannot carry it")
        print(f"{ep}\t{verdict}")
        rows += 1
if rows == 0:
    sys.exit(f"{path}: no rows. An empty table passes every test it has.")
PY
}

@test "endpoint table: the connect/pull validator answers every row as the table says (#717)" {
  local rows disagreed=0 checked=0 endpoint want got
  rows="$(table_rows)"

  while IFS=$'\t' read -r endpoint want; do
    [ -n "$endpoint" ] || continue
    if python3 "$SCRIPTS/internal/validate-endpoint.py" "$endpoint" 2>/dev/null; then
      got=allow
    else
      got=deny
    fi
    checked=$(( checked + 1 ))
    if [ "$got" != "$want" ]; then
      echo "validate-endpoint.py: $endpoint -> $got, table says $want"
      disagreed=$(( disagreed + 1 ))
    fi
  done <<< "$rows"

  # Both guards matter. Without the first, a table this loop never entered is
  # indistinguishable from a table it walked clean.
  [ "$checked" -eq "$(grep -c . "$TABLE")" ]
  [ "$checked" -gt 0 ]
  [ "$disagreed" -eq 0 ]
}

@test "endpoint table: the node harness reads the same file this one does (#717)" {
  # Not a formality. The property being defended is "one table, two readers";
  # if the other harness were pointed at its own copy, both could be green while
  # the two implementations disagreed — which is the whole failure of #717.
  local shared="fixtures/endpoint-verdicts.jsonl"
  grep -qF "$shared" "$BATS_TEST_DIRNAME/test_endpoint_table_py.bats"
  grep -qF "$shared" "$BATS_TEST_DIRNAME/test_endpoint_table_node.bats"
}
