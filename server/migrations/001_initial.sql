CREATE TABLE IF NOT EXISTS server_metadata (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  server_instance_id UUID NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS teams (
  team_id UUID PRIMARY KEY,
  team_name TEXT NOT NULL,
  current_seq BIGINT NOT NULL DEFAULT 0 CHECK (current_seq >= 0),
  min_available_seq BIGINT NOT NULL DEFAULT 0,
  policy_revision BIGINT NOT NULL DEFAULT 0 CHECK (policy_revision >= 0),
  accepted_envelope_versions INTEGER[] NOT NULL DEFAULT ARRAY[1],
  write_allowed_ciphers TEXT[] NOT NULL DEFAULT ARRAY['none']::TEXT[],
  max_blob_bytes INTEGER NOT NULL DEFAULT 1048576
    CHECK (max_blob_bytes BETWEEN 1 AND 1048576),
  members_revision BIGINT NOT NULL DEFAULT 0 CHECK (members_revision >= 0),
  CHECK (min_available_seq >= 0 AND min_available_seq <= current_seq)
);

CREATE TABLE IF NOT EXISTS team_policy_history (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  policy_revision BIGINT NOT NULL CHECK (policy_revision >= 0),
  effective_from_seq BIGINT NOT NULL CHECK (effective_from_seq >= 1),
  accepted_envelope_versions INTEGER[] NOT NULL,
  write_allowed_ciphers TEXT[] NOT NULL,
  PRIMARY KEY (team_id, policy_revision)
);

CREATE INDEX IF NOT EXISTS team_policy_history_effective_idx
  ON team_policy_history(team_id, effective_from_seq, policy_revision DESC);

CREATE TABLE IF NOT EXISTS messages (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  id UUID NOT NULL,
  team_seq BIGINT NOT NULL CHECK (team_seq >= 1),
  server_received_at TIMESTAMPTZ(6) NOT NULL DEFAULT clock_timestamp(),
  envelope_v INTEGER NOT NULL,
  cipher TEXT NOT NULL,
  key_id TEXT,
  blob TEXT NOT NULL,
  envelope_digest BYTEA NOT NULL,
  PRIMARY KEY (team_id, id),
  UNIQUE (team_id, team_seq)
);

CREATE TABLE IF NOT EXISTS message_tombstones (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  id UUID NOT NULL,
  original_team_seq BIGINT NOT NULL CHECK (original_team_seq >= 1),
  envelope_digest BYTEA NOT NULL,
  PRIMARY KEY (team_id, id)
);

CREATE TABLE IF NOT EXISTS members (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  member_id UUID NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (team_id, member_id),
  UNIQUE (team_id, name)
);

CREATE TABLE IF NOT EXISTS member_identity_history (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  member_id UUID NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (team_id, name)
);

CREATE INDEX IF NOT EXISTS member_identity_history_member_idx
  ON member_identity_history(team_id, member_id);

CREATE TABLE IF NOT EXISTS registrations (
  team_id UUID NOT NULL,
  registration_id UUID NOT NULL,
  member_id UUID NOT NULL,
  installation_id UUID NOT NULL,
  type TEXT NOT NULL,
  PRIMARY KEY (team_id, registration_id),
  FOREIGN KEY (team_id, member_id)
    REFERENCES members(team_id, member_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS registration_identity_history (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  registration_id UUID NOT NULL,
  member_id UUID NOT NULL,
  PRIMARY KEY (team_id, registration_id)
);
