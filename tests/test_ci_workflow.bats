#!/usr/bin/env bats

@test "remote CI watches the data plane and its sync contracts" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'scripts/internal/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'scripts/drivers/storage/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'scripts/lib/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'tests/*sync*.*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'tests/test_remote*.bats' "$workflow"
  [ "$status" -eq 0 ]
}

@test "age-v1 CI exercises the encrypted onboarding CLI with pinned tools" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'filippo.io/age/cmd/age-keygen@v1.3.1' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'echo "$(go env GOPATH)/bin" >> "$GITHUB_PATH"' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'command -v age >/dev/null' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'command -v age-keygen >/dev/null' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "bats --print-output-on-failure --filter 'remote unlock:' tests/test_remote.bats" "$workflow"
  [ "$status" -eq 0 ]
}
