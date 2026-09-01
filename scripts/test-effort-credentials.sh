#!/usr/bin/env bash
# Credential-free regression test for the PER-EFFORT credential contract.
# Requires Docker and a locally built image containing the current launcher:
#
#   export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.build.yaml
#   docker compose build cli
#   scripts/test-effort-credentials.sh compliance-claw:local
#
# Same shape and the same reasoning as scripts/test-file-secrets.sh: fake canary
# values only, direct `docker run` so it is independent of the operator's Compose
# files and `.env`, and it never calls Pretorin or a model provider.
#
# WHAT THIS GATE EXISTS FOR. scripts/parse-efforts.py's self-test proves the
# credential LADDER resolves the right path. It cannot prove the other half of
# the contract — that the value actually reaches the MCP child, that it does NOT
# reach `docker inspect` or `ps`, that a wrong or absent credential FAILS CLOSED
# instead of falling through to the container-wide default, and that the scope
# pin comes from the mounted efforts.yaml rather than from the caller.
#
# The fall-through is the one that matters most. PID 1 exports the legacy
# PRETORIN_API_KEY for the whole container, so a launcher that failed to resolve
# its own credential and carried on would silently run effort B's agent on effort
# A's key — writing to the wrong compliance scope with a perfectly valid
# credential. That must be impossible, not unlikely.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="${1:-compliance-claw:local}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-effort-creds.XXXXXX")"

# The per-effort key. If this string ever appears in `docker inspect`, in a
# process command line, or in a log line, the test fails.
CANARY_EFFORT="CANARY-EFFORT-KEY-6b21f4"
# The container-wide legacy key. If a child ever runs on THIS instead of the one
# above, the isolation the whole architecture rests on is gone.
CANARY_LEGACY="CANARY-LEGACY-KEY-9de07c"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
        [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
head1() { printf '\n%s\n' "$1"; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "effort-creds-test: image not found: ${IMAGE}" >&2
       echo "  build it first: docker compose build cli" >&2; exit 1; }

mkdir -p "$TMP/credentials"
# 0701, not 0700: the DIRECTORY is bind-mounted whole, and the container's
# uid-1000 user must be able to traverse it to open a file inside. A 0700
# directory makes every credential report "does not exist" — a permission problem
# wearing a missing-file message. Docker Desktop masks this on macOS by presenting
# mounts as owned by the container user; Linux does not. Mirrors
# container_traversable_dir() in scripts/clawctl.
chmod 701 "$TMP/credentials"
printf '%s' "$CANARY_EFFORT" > "$TMP/credentials/hipaa-key"
printf '%s' ''               > "$TMP/credentials/empty-key"
chmod 604 "$TMP/credentials"/*
printf '%s' "$CANARY_LEGACY" > "$TMP/legacy-key"
chmod 604 "$TMP/legacy-key"

cat > "$TMP/efforts.yaml" <<'Y'
efforts:
  - name: uses-named
    system_id: 11111111-1111-4111-8111-111111111111
    framework_id: hipaa
    credential_ref: hipaa-key
    slack_channel_id: C0CRED001
    targets:
      - name: t
        url: https://example.com/t.git
  - name: uses-default
    system_id: 22222222-2222-4222-8222-222222222222
    framework_id: soc2
    credential_ref: default
    slack_channel_id: C0CRED002
    targets:
      - name: t
        url: https://example.com/t.git
  - name: uses-missing
    system_id: 33333333-3333-4333-8333-333333333333
    framework_id: cmmc
    credential_ref: no-such-key
    slack_channel_id: C0CRED003
    targets:
      - name: t
        url: https://example.com/t.git
  - name: uses-empty
    system_id: 44444444-4444-4444-8444-444444444444
    framework_id: soc2
    credential_ref: empty-key
    slack_channel_id: C0CRED004
    targets:
      - name: t
        url: https://example.com/t.git
Y

# The launcher ends in `exec "$PRETORIN_BIN" mcp-serve`. Pointing CC_PRETORIN_BIN
# at this probe means we observe the environment the real MCP child would have
# received, without starting a server that waits on stdin forever.
cat > "$TMP/probe.sh" <<'P'
#!/bin/sh
echo "PROBE_KEY=[${PRETORIN_API_KEY:-}]"
echo "PROBE_KEYFILE=[${PRETORIN_API_KEY_FILE:-}]"
echo "PROBE_SYSTEM=[${PRETORIN_SYSTEM_ID:-}]"
echo "PROBE_FRAMEWORK=[${PRETORIN_FRAMEWORK_ID:-}]"
echo "PROBE_ARGV=[$*]"
P
chmod 0755 "$TMP/probe.sh"

# The platform this image actually is. The repo targets linux/amd64 (upstream
# ships no linux/arm64 Pretorin binary), and CI builds natively there — but a
# developer building on Apple Silicon can end up with an arm64 image, and
# `docker run --platform linux/amd64` against it does not fail loudly, it tries
# to PULL and then reports "unable to find image". Read the platform off the
# image instead of asserting one, so this gate tests what is in front of it.
PLATFORM="$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || echo '')"
[ -n "$PLATFORM" ] || { echo "effort-creds-test: cannot read the platform of ${IMAGE}" >&2; exit 1; }

# EVERY ASSERTION BELOW THAT CHECKS FOR THE *ABSENCE* OF SOMETHING IS ONLY
# MEANINGFUL IF THE LAUNCHER ACTUALLY RAN.
#
# This bit the first version of this file: with the image unresolvable, every
# `docker run` printed a daemon error, and three absence checks — "the launcher
# overrides the inherited key", "a missing credential refuses", "an empty
# credential refuses" — all reported PASS. They were passing on a command that
# never executed. So `launch` now refuses to hand back output that came from a
# broken invocation rather than from the launcher.
DOCKER_BROKEN=0
launch() {
  local effort="$1"; shift
  local out
  out="$(docker run --rm --platform "$PLATFORM" \
    --entrypoint /opt/compliance-claw/pretorin-mcp-launch \
    -e PRETORIN_API_KEY="$CANARY_LEGACY" \
    -e CC_PRETORIN_BIN=/probe.sh \
    "$@" \
    --mount "type=bind,src=${TMP}/efforts.yaml,dst=/etc/compliance-claw/efforts.yaml,readonly" \
    --mount "type=bind,src=${TMP}/credentials,dst=/run/compliance-claw/credentials,readonly" \
    --mount "type=bind,src=${TMP}/legacy-key,dst=/run/secrets/pretorin_api_key,readonly" \
    --mount "type=bind,src=${TMP}/probe.sh,dst=/probe.sh,readonly" \
    "$IMAGE" "$effort" 2>&1 || true)"

  # A docker-level failure is NOT a test result. Say so, and make it impossible
  # for an absence check to read it as success.
  case "$out" in
    *"Unable to find image"*|*"pull access denied"*|*"Error response from daemon"*|*"exec format error"*)
      DOCKER_BROKEN=1
      printf 'DOCKER_INVOCATION_FAILED %s\n' "$out"
      return 0 ;;
  esac
  printf '%s\n' "$out"
}

# Prove the harness itself works before trusting a single absence check.
SANITY="$(launch uses-named)"
if [ "$DOCKER_BROKEN" = 1 ]; then
  echo "effort-creds-test: the image will not run on this host." >&2
  printf '%s\n' "$SANITY" | head -3 >&2
  echo "  image platform: ${PLATFORM}; host: $(uname -m)" >&2
  echo "  Build for this platform, or run this gate where the image is native (CI)." >&2
  exit 1
fi
case "$SANITY" in
  *PROBE_KEY=*) ;;
  *) echo "effort-creds-test: the launcher did not reach the probe; every absence" >&2
     echo "  check below would be meaningless. Output was:" >&2
     printf '%s\n' "$SANITY" | head -5 >&2
     exit 1 ;;
esac

head1 "A. the named credential reaches the child, and the pin comes from the file"

OUT="$(launch uses-named || true)"
case "$OUT" in
  *"PROBE_KEY=[${CANARY_EFFORT}]"*) ok "the effort's OWN key reaches the MCP child" ;;
  *) bad "the effort's own key reaches the MCP child" "$(printf '%s' "$OUT" | head -3)" ;;
esac
# THE FALL-THROUGH TEST. The legacy key is in the environment; the child must not
# be running on it.
case "$OUT" in
  *"PROBE_KEY=[${CANARY_LEGACY}]"*)
    bad "the launcher OVERRIDES the inherited container-wide key" \
        "the child inherited the legacy key — effort isolation is broken" ;;
  *"PROBE_KEY=[${CANARY_EFFORT}]"*)
    ok "the launcher OVERRIDES the inherited container-wide key" ;;
  *) bad "the launcher OVERRIDES the inherited container-wide key" \
         "the probe did not report a key at all, so this proves nothing" ;;
esac
case "$OUT" in
  *"PROBE_SYSTEM=[11111111-1111-4111-8111-111111111111]"*)
    ok "PRETORIN_SYSTEM_ID is derived from the mounted efforts.yaml" ;;
  *) bad "PRETORIN_SYSTEM_ID is derived from the mounted efforts.yaml" ;;
esac
case "$OUT" in
  *"PROBE_FRAMEWORK=[hipaa]"*) ok "PRETORIN_FRAMEWORK_ID is derived from the mounted efforts.yaml" ;;
  *) bad "PRETORIN_FRAMEWORK_ID is derived from the mounted efforts.yaml" ;;
esac
case "$OUT" in
  *"PROBE_ARGV=[mcp-serve]"*) ok "it execs the CLI with exactly 'mcp-serve'" ;;
  *) bad "it execs the CLI with exactly 'mcp-serve'" ;;
esac

head1 "B. credential_ref: default resolves to the already-mounted legacy secret"

OUT="$(launch uses-default || true)"
case "$OUT" in
  *"PROBE_KEY=[${CANARY_LEGACY}]"*)
    ok "'default' reads /run/secrets/pretorin_api_key (no second file needed)" ;;
  *) bad "'default' reads /run/secrets/pretorin_api_key" "$(printf '%s' "$OUT" | head -3)" ;;
esac
case "$OUT" in
  *"PROBE_KEYFILE=[/run/secrets/pretorin_api_key]"*)
    ok "the _FILE variable points at the same file, not the container default" ;;
  *) bad "the _FILE variable points at the resolved file" ;;
esac

head1 "C. fail closed — never fall back to the container-wide key"

# Each refusal must be the LAUNCHER's own, not silence from a broken invocation.
refuses() {
  local out="$1" label="$2"
  case "$out" in
    *PROBE_KEY=*) bad "$label" "it started the child anyway" ; return ;;
  esac
  case "$out" in
    *"pretorin-mcp-launch: ERROR"*) ok "$label" ;;
    *) bad "$label" "no launcher refusal in the output: $(printf '%s' "$out" | head -1)" ;;
  esac
}

OUT="$(launch uses-missing || true)"
refuses "$OUT" "a MISSING credential file refuses; the child never starts"
case "$OUT" in
  *"no-such-key"*) ok "the refusal names the credential" ;;
  *) bad "the refusal names the credential" "$(printf '%s' "$OUT" | head -2)" ;;
esac
case "$OUT" in
  *"clawctl credential add"*) ok "the refusal names the fix" ;;
  *) bad "the refusal names the fix" ;;
esac

OUT="$(launch uses-empty || true)"
refuses "$OUT" "an EMPTY credential file refuses ('not configured', not 'the empty key')"

OUT="$(launch no-such-effort || true)"
refuses "$OUT" "an UNDECLARED effort name refuses"

# The runtime half of the Dockerfile's `RUN python3 --version` assertion. If the
# parser is unreachable, the child must not start with an inherited credential.
OUT="$(docker run --rm --platform "$PLATFORM" \
  --entrypoint /opt/compliance-claw/pretorin-mcp-launch \
  -e PRETORIN_API_KEY="$CANARY_LEGACY" \
  -e CC_PRETORIN_BIN=/probe.sh \
  -e CC_PARSE_EFFORTS=/opt/compliance-claw/does-not-exist.py \
  --mount "type=bind,src=${TMP}/efforts.yaml,dst=/etc/compliance-claw/efforts.yaml,readonly" \
  --mount "type=bind,src=${TMP}/credentials,dst=/run/compliance-claw/credentials,readonly" \
  --mount "type=bind,src=${TMP}/probe.sh,dst=/probe.sh,readonly" \
  "$IMAGE" uses-named 2>&1 || true)"
refuses "$OUT" "a missing parser fails closed (no inherited credential)"

head1 "D. containment — the value never leaves the file"

# `docker inspect` on a container started the way the launcher is used. The key
# is READ FROM A FILE inside the container, so it must never appear in Config.Env.
CID="$(docker run -d --platform "$PLATFORM" \
  --entrypoint /bin/sh \
  -e PRETORIN_API_KEY_FILE=/run/compliance-claw/credentials/hipaa-key \
  --mount "type=bind,src=${TMP}/efforts.yaml,dst=/etc/compliance-claw/efforts.yaml,readonly" \
  --mount "type=bind,src=${TMP}/credentials,dst=/run/compliance-claw/credentials,readonly" \
  "$IMAGE" -c 'sleep 30' 2>/dev/null)"
if [ -n "$CID" ]; then
  ENVJSON="$(docker inspect --format '{{json .Config.Env}}' "$CID" 2>/dev/null || echo '')"
  case "$ENVJSON" in
    *"$CANARY_EFFORT"*) bad "the key does NOT appear in docker inspect" ;;
    *) ok "the key does NOT appear in docker inspect (only the path does)" ;;
  esac
  case "$ENVJSON" in
    *"/run/compliance-claw/credentials/hipaa-key"*)
      ok "only the PATH is container configuration" ;;
    *) bad "the path is container configuration" ;;
  esac
  docker rm -f "$CID" >/dev/null 2>&1 || true
else
  bad "could not start the inspect probe container"
fi

# The launcher must not put the value in argv, where `ps` would show it to every
# process in the container — including the agent's unsandboxed tool execution.
OUT="$(launch uses-named || true)"
case "$OUT" in
  *"PROBE_ARGV=[mcp-serve]"*) ok "the value is NOT in the child's argv" ;;
  *) bad "the value is NOT in the child's argv" "argv line: $(printf '%s' "$OUT" | grep PROBE_ARGV || true)" ;;
esac
# Its own diagnostics name the credential but never print it.
case "$OUT" in
  *"credential=hipaa-key"*) ok "the launcher logs the credential NAME" ;;
  *) bad "the launcher logs the credential name" ;;
esac
LOGLINES="$(printf '%s' "$OUT" | grep -v '^PROBE_KEY=' || true)"
case "$LOGLINES" in
  *"$CANARY_EFFORT"*) bad "no log line contains the value" ;;
  *) ok "no log line contains the value" ;;
esac

printf '\n'
printf 'effort-credential test: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
