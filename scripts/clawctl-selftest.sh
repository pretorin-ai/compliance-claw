#!/usr/bin/env bash
#
# clawctl-selftest.sh — sourced by `scripts/clawctl --self-test`.
#
# NO CREDENTIALS, NO CONTAINERS, NO NETWORK. Every docker invocation is
# intercepted by a stub on PATH that RECORDS its argv, so the tests can assert on
# what clawctl would run rather than on what it says it would run.
#
# The three properties worth proving: migrate converts a real targets.yaml and
# refuses cleanly the second time; `plan` has NO side effects (not one docker
# invocation, not one byte changed); and `apply` builds the right commands — the
# scope pin and named credential on EVERY Pretorin invocation, `context set` on
# none, and each echoed line byte-identical to the argv issued. The last would
# otherwise rot silently: a `plan` that drifts from `apply` is worse than none.

# shellcheck shell=bash

ST_PASS=0
ST_FAIL=0
st_ok()   { ST_PASS=$((ST_PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
st_bad()  { ST_FAIL=$((ST_FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
            [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
st_head() { printf '\n%s\n' "$1"; }

# A stub `docker` that records every invocation and answers the few questions
# clawctl asks. Written to $1/docker; $2 is the record file.
st_write_stub_docker() {
  local dir="$1" record="$2" mode="${3:-answer}" root="${4:-}" efile="${5:-}"
  # STUB_OC_CONFIG / STUB_OC_FAIL are read from the ENVIRONMENT by the generated
  # stub, so one stub serves every configuration case without being rewritten.
  mkdir -p "$dir"
  cat > "${dir}/docker" <<STUB
#!/usr/bin/env bash
STUB_ATTACHED="\${STUB_ATTACHED:-}"
# DRAIN STDIN, BECAUSE REAL \`docker compose run\` DOES.
#
# Compose attaches the caller's stdin even with -T, so an unguarded call inside
# \`while read ... done < <(...)\` eats the rest of the loop's input and every
# later iteration is silently skipped. A stub ignoring stdin cannot reproduce
# that — the first version of this file reported 38/38 with the bug deliberately
# reintroduced. Consuming stdin as compose does makes a missing \`< /dev/null\`
# lose the second effort here too.
# THE AGENT-WORKSPACE SCRIPT ARRIVES ON STDIN AND IS EXECUTED FOR REAL, with
# /home/node/.openclaw rewritten to STUB_WS_ROOT. A stub that only recorded argv
# let a bug through where apply logged every workspace, wrote none, and exited 0.
case " \$* " in
  *" cli sh -s "*)
    _script="\$(cat)"
    # STUB_WS_FAIL=snapshot|restore breaks exactly one half of the workspace
    # transaction, which is the only way to test that a missing backup stops the
    # run and that a failed restore is not reported as a successful rollback.
    case "\$_script" in
      *CC_WS_SNAPSHOT_OK*) [ "\${STUB_WS_FAIL:-}" = snapshot ] && exit 1 ;;
      *CC_WS_RESTORED*)    [ "\${STUB_WS_FAIL:-}" = restore ]  && exit 1 ;;
    esac
    _rest=""; _hit=0
    for a in "\$@"; do
      if [ "\$_hit" = 1 ]; then
        case "\$a" in -s|--) continue ;; esac
        _rest="\$_rest \$(printf '%s' "\$a" | sed "s|/home/node/.openclaw|\${STUB_WS_ROOT:-/tmp/stub-ws}|")"
      fi
      [ "\$a" = sh ] && _hit=1
    done
    # Run it against the rewritten host path, then map the path back on the way
    # out: clawctl asserts on the CONTAINER path it asked for, and a stub that
    # reported its own scratch directory would fail a check that is correct.
    printf '%s' "\$_script" | sh -s -- \$_rest \
      | sed "s|\${STUB_WS_ROOT:-/tmp/stub-ws}|/home/node/.openclaw|g"
    exit \$?
    ;;
esac

# THE PATCH ARRIVES ON STDIN, SO IT IS HANDLED BEFORE THE DRAIN BELOW.
# \`config patch --stdin\` is the one call whose stdin is the payload rather than
# an accident of compose attaching it. Draining first would leave the patch
# empty and the stub would silently apply nothing — which is exactly how this
# section first reported a config that had never been written.
# \`openclaw config patch --stdin [--dry-run]\`, applied to the stand-in config by
# the REAL merge semantics rather than a guess: objects merge, arrays and scalars
# replace, null deletes. Getting this wrong in the stub would make the tests
# assert against behaviour OpenClaw does not have.
case " \$* " in
  *" openclaw config patch --stdin "*|*" openclaw config patch --stdin")
    _patch="\$(cat)"
    case " \$* " in
      *" --dry-run "*|*" --dry-run")
        [ "\${STUB_OC_FAIL}" = dryrun ] && exit 1
        exit 0 ;;
    esac
    [ "\${STUB_OC_FAIL}" = patch ] && exit 1
    # STUB_OC_FAIL=verify models "the patch applied but the result is not what was
    # asked for" — one agent silently missing. That is what verification is FOR,
    # and it is deliberately not "the gateway is unreachable": an unreachable
    # gateway would also break the ROLLBACK's own health check, so the rollback
    # test could never distinguish a good restore from a broken one.
    CC_DROP=""
    case "\${STUB_OC_FAIL}" in verify|rollback) CC_DROP=1 ;; esac
    CC_DROP="\$CC_DROP" CC_PATCH="\$_patch" CC_CFG="\${STUB_OC_CONFIG}" python3 -c '
import json, os
patch = json.loads(os.environ["CC_PATCH"])
try:
    cfg = json.load(open(os.environ["CC_CFG"]))
except Exception:
    cfg = {}
def merge(dst, src):
    for k, v in src.items():
        if v is None:
            dst.pop(k, None)
        elif isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v
merge(cfg, patch)
if os.environ.get("CC_DROP") and cfg.get("agents", {}).get("list"):
    cfg["agents"]["list"] = cfg["agents"]["list"][:-1]
cfg.setdefault("meta", {})["lastTouchedAt"] = "stub"
json.dump(cfg, open(os.environ["CC_CFG"], "w"), indent=2, sort_keys=True)
'
    exit 0 ;;
esac


# Only \`compose run\` attaches stdin, and only when stdin is not a terminal —
# draining unconditionally hangs forever against a tty. \`logs\`, \`inspect\` and
# \`rm\` never touch it.
case " \$* " in
  *" run "*) [ -t 0 ] || cat >/dev/null 2>&1 || true ;;
esac
# Record the invocation, shell-quoted, exactly as clawctl issued it.
{ printf 'docker'; for a in "\$@"; do printf ' %q' "\$a"; done; printf '\n'; } >> '${record}'
if [ '${mode}' = refuse ]; then
  echo "STUB DOCKER WAS INVOKED — this command must not start containers" >&2
  exit 97
fi
# The lock sidecar: report a plausible container id.
case " \$* " in
  *" run -d "*) echo "0123456789abcdef0123"; exit 0 ;;
esac
case "\${1:-}" in
  logs)    echo CLAWCTL_LOCK_HELD; exit 0 ;;
  inspect) exit 0 ;;
  rm)      exit 0 ;;
esac
# preflight show -> an artifact describing a SUCCESSFUL onboarding of the targets
# named in STUB_TARGETS, so \`ol_assert\` passes and apply proceeds to the config
# stage. STUB_ONBOARD=fail returns the empty artifact instead, which is what a
# scope that was never onboarded looks like — that is the negative fixture for
# "a failed effort must not receive an agent".
STUB_TARGETS="\${STUB_TARGETS:-}"
STUB_ONBOARD="\${STUB_ONBOARD:-ok}"
case " \$* " in
  *" preflight show "*)
    if [ "\$STUB_ONBOARD" = fail ] || [ -z "\$STUB_TARGETS" ]; then
      echo '{"kinds":[]}'; exit 0
    fi
    CC_T="\$STUB_TARGETS" python3 -c '
import json, os
res = [{"spec": {"name": t, "params": {"path": "/workspace/targets/" + t},
                 "capabilities": ["commit_history"]},
        "last_result": {"status": "connected"}}
       for t in os.environ["CC_T"].split()]
print(json.dumps({"kinds": [{"kind": "code_repository", "resolvers": res}]}))'
    exit 0 ;;
esac

# --- the OpenClaw configuration stage -------------------------------------
#
# STUB_OC_CONFIG names a file standing in for the config INSIDE the volume, so
# the tests can seed a starting configuration and inspect what apply did to it.
# STUB_OC_FAIL selects a failure to inject: patch | verify.
STUB_OC_CONFIG="\${STUB_OC_CONFIG:-}"
STUB_OC_FAIL="\${STUB_OC_FAIL:-}"

# Reading and copying the config in the volume.
#
# SNAPSHOT AND RESTORE ARE THE SAME TWO PATHS IN THE OPPOSITE ORDER, so they are
# told apart by which one comes FIRST — matching on ".pre-apply." alone made a
# restore re-snapshot instead, silently leaving the broken config in place and
# making a working rollback look like a failed one.
CFG_PATH="/home/node/.openclaw/openclaw.json"
case " \$* " in
  # restore: cp -p '<config>.pre-apply.<ts>' '<config>'
  *"cp -p '\${CFG_PATH}.pre-apply."*)
    # STUB_OC_FAIL=rollback: the restore itself fails. That is the case where the
    # deployment is left in an unknown state and the operator needs exact manual
    # recovery steps rather than a reassuring summary.
    [ "\${STUB_OC_FAIL}" = rollback ] && exit 1
    cp "\${STUB_OC_CONFIG}.snap" "\${STUB_OC_CONFIG}" 2>/dev/null || true; exit 0 ;;
  # restore on a deployment that had NO config: the undo is a removal, not a copy.
  *"rm -f '\${CFG_PATH}'"*)
    [ "\${STUB_OC_FAIL}" = rollback ] && exit 1
    rm -f "\${STUB_OC_CONFIG}"; exit 0 ;;
  # snapshot: the config-copy step, which proves itself with a marker carrying
  # whether a config existed at all. STUB_OC_FAIL=cfgsnapshot makes the copy fail,
  # which must stop the run rather than yield an empty "fresh deployment" snapshot.
  *"cp -p '\${CFG_PATH}' '"*)
    [ "\${STUB_OC_FAIL}" = cfgsnapshot ] && exit 1
    if [ -e "\${STUB_OC_CONFIG}" ]; then
      cp "\${STUB_OC_CONFIG}" "\${STUB_OC_CONFIG}.snap" 2>/dev/null || exit 1
      echo "CC_CFG_SNAPSHOT_OK had=1"
    else
      : > "\${STUB_OC_CONFIG}.snap" || exit 1
      echo "CC_CFG_SNAPSHOT_OK had=0"
    fi
    exit 0 ;;
  # reading the snapshot back (verify-rollback compares against it)
  *"cat '\${CFG_PATH}.pre-apply."*)
    cat "\${STUB_OC_CONFIG}.snap" 2>/dev/null || true; exit 0 ;;
  # reading the live config
  *" cli sh -c cat "*|*"cli sh -c "*"openclaw.json"*)
    cat "\${STUB_OC_CONFIG}" 2>/dev/null || true; exit 0 ;;
esac

# The gateway container: recreate, and the exec'd verification commands.
case " \$* " in
  *" up -d --force-recreate openclaw "*)
    [ "\${STUB_OC_FAIL}" = restart ] && exit 1
    exit 0 ;;
  *" exec -T openclaw "*)
    case " \$* " in
      *" openclaw health"*) echo '{"ok":true}'; exit 0 ;;
      *" agents list "*)
        CC_CFG="\${STUB_OC_CONFIG}" python3 -c '
import json, os
cfg = json.load(open(os.environ["CC_CFG"]))
print(json.dumps({"agents": cfg.get("agents", {}).get("list", []),
                  "bindings": cfg.get("bindings", [])}))
'
        exit 0 ;;
      *" mcp list "*)
        CC_CFG="\${STUB_OC_CONFIG}" python3 -c '
import json, os
cfg = json.load(open(os.environ["CC_CFG"]))
print(json.dumps({"servers": sorted(cfg.get("mcp", {}).get("servers", {}))}))
'
        exit 0 ;;
    esac
    exit 0 ;;
esac
# The two probe calls validate makes. check_context echoes whatever scope the
# process was pinned to; get_compliance_status reports the system's ATTACHED
# frameworks, which is what the pair check reads. STUB_ATTACHED controls it.
case " \$* " in
  *" check_context "*)
    # The pins do NOT arrive as -e flags: the real launcher derives them from
    # efforts.yaml. Stand in for it the same way, so the stub cannot report a
    # scope the launcher would not have produced.
    _effort=""
    for a in "\$@"; do
      case "\$a" in MCP_CALL_COMMAND=*) _effort="\${a##* }" ;; esac
    done
    _scope="\$(python3 '${root}/scripts/parse-efforts.py' scope "\$_effort" '${efile}' 2>/dev/null)"
    _sys="\$(printf '%s' "\$_scope" | cut -f1)"
    _fw="\$(printf '%s' "\$_scope" | cut -f2)"
    printf '{"connected":true,"active_system":{"id":"%s","name":"Stub"},"active_framework_id":"%s"}\n' "\$_sys" "\$_fw"
    exit 0 ;;
  *" get_compliance_status "*)
    printf '{"system_id":"x","system_name":"Stub","frameworks":['
    _first=1
    for f in \${STUB_ATTACHED:-soc2}; do
      [ "\$_first" = 1 ] || printf ','
      printf '{"framework_id":"%s"}' "\$f"; _first=0
    done
    printf ']}\n'
    exit 0 ;;
esac
exit 0
STUB
  chmod 0755 "${dir}/docker"
}

# A fixture single-effort targets.yaml, in the shape a real one has.
st_fixture_targets() {
  cat > "$1" <<'Y'
# fixture
system_id: 13c1f44e-b66d-417c-8604-4ac7b988b411
framework_id: soc2
targets:
  - name: simple-crm
    url: https://github.com/pretorin-ai/simple-crm.git
    ref: main
  - name: other
    url: https://example.com/other.git
Y
}

# A manifest of a directory tree: path + size + mtime + mode, for proving that
# nothing changed. Content hashes would be stronger but need a portable sha
# binary; size+mtime+mode catches every write this code could make.
st_manifest() {
  find "$1" -type f -o -type d 2>/dev/null | LC_ALL=C sort | while read -r p; do
    printf '%s %s\n' "$p" "$(stat -c '%s:%Y:%a' "$p" 2>/dev/null || stat -f '%z:%m:%Lp' "$p" 2>/dev/null || echo '?')"
  done
}

clawctl_self_test() {
  local root tmp bin record
  root="$REPO_ROOT"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/clawctl-selftest.XXXXXX")"
  bin="${tmp}/bin"
  record="${tmp}/docker-calls.txt"

  local T="${tmp}/targets.yaml"
  local E="${tmp}/efforts.yaml"
  local S="${tmp}/secrets"
  mkdir -p "$S"
  st_fixture_targets "$T"

  # ---------------------------------------------------------------- migrate
  st_head "1. migrate"

  local out
  if out="$(TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" COMPLIANCE_CLAW_SECRET_DIR="$S" \
              bash "${root}/scripts/clawctl" migrate --name crm-soc2 --slack-channel-id C0SOC2AAA 2>&1)"; then
    st_ok "migrate converts a single-effort targets.yaml"
  else
    st_bad "migrate converts a single-effort targets.yaml" "$out"
  fi

  if [ -f "$E" ]; then
    st_ok "efforts.yaml was written"
  else
    st_bad "efforts.yaml was written"
  fi

  if python3 "${root}/scripts/parse-efforts.py" validate "$E" >/dev/null 2>&1; then
    st_ok "the generated file validates against its own schema"
  else
    st_bad "the generated file validates against its own schema"
  fi

  local got
  got="$(python3 "${root}/scripts/parse-efforts.py" scope crm-soc2 "$E")"
  if [ "$got" = "$(printf '13c1f44e-b66d-417c-8604-4ac7b988b411\tsoc2\tdefault')" ]; then
    st_ok "scope and credential_ref carried over (credential_ref: default)"
  else
    st_bad "scope and credential_ref carried over" "got: $got"
  fi

  got="$(python3 "${root}/scripts/parse-efforts.py" list crm-soc2 "$E")"
  if [ "$got" = "$(printf 'simple-crm\thttps://github.com/pretorin-ai/simple-crm.git\tfalse\tmain\nother\thttps://example.com/other.git\tfalse\t')" ]; then
    st_ok "every target carried over verbatim, field order preserved"
  else
    st_bad "every target carried over verbatim" "got: $got"
  fi

  if grep -q 'connections' "$E"; then
    st_bad "no reserved 'connections' section is emitted" "it belongs to a later change"
  else
    st_ok "no reserved 'connections' section is emitted"
  fi

  # targets.yaml must be untouched: it is still what the deployment reads.
  if diff -q "$T" <(st_fixture_targets /dev/stdout) >/dev/null 2>&1; then
    st_ok "targets.yaml was NOT modified"
  else
    st_bad "targets.yaml was NOT modified"
  fi

  # Idempotence: a second migrate refuses, and does not rewrite.
  local before after plan_out
  before="$(st_manifest "$tmp")"
  if TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" COMPLIANCE_CLAW_SECRET_DIR="$S" \
       bash "${root}/scripts/clawctl" migrate --name crm-soc2 --slack-channel-id C0SOC2AAA >/dev/null 2>&1; then
    st_bad "a second migrate refuses" "it succeeded, which means it may have rewritten the file"
  else
    st_ok "a second migrate refuses cleanly (write-if-absent)"
  fi
  after="$(st_manifest "$tmp")"
  if [ "$before" = "$after" ]; then
    st_ok "the refused migrate changed nothing on disk"
  else
    st_bad "the refused migrate changed nothing on disk" "$(diff <(echo "$before") <(echo "$after") | head -5)"
  fi

  # system_id is always a UUID, so a name must be asked for, never derived.
  rm -f "$E"
  if out="$(TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" COMPLIANCE_CLAW_SECRET_DIR="$S" \
              bash "${root}/scripts/clawctl" migrate --slack-channel-id C0SOC2AAA 2>&1)"; then
    st_bad "migrate refuses to derive an effort name" "it generated one"
  else
    case "$out" in
      *"--name"*) st_ok "migrate refuses to derive a name and names --name" ;;
      *) st_bad "migrate refuses to derive a name" "message did not mention --name" ;;
    esac
  fi
  [ -e "$E" ] && st_bad "the refused migrate wrote no file" || st_ok "the refused migrate wrote no file"

  # THE CHANNEL IS THE OTHER THING THAT CANNOT BE DERIVED. targets.yaml has no
  # Slack in it at all, and a placeholder would produce a file that validates and
  # routes nowhere — the exact failure that looks like a broken bot.
  if out="$(TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" COMPLIANCE_CLAW_SECRET_DIR="$S" \
              bash "${root}/scripts/clawctl" migrate --name crm-soc2 2>&1)"; then
    st_bad "migrate refuses to invent a Slack channel id" "it generated one"
  else
    case "$out" in
      *"--slack-channel-id"*) st_ok "migrate refuses to invent a channel and names the flag" ;;
      *) st_bad "migrate refuses to invent a channel" "message did not name the flag" ;;
    esac
  fi
  [ -e "$E" ] && st_bad "that refusal wrote no file either" || st_ok "that refusal wrote no file either"

  # A D id is a DM conversation, not a channel; refusing it here is what keeps a
  # DM from being configured as an effort's home.
  if out="$(TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" COMPLIANCE_CLAW_SECRET_DIR="$S" \
              bash "${root}/scripts/clawctl" migrate --name crm-soc2 \
              --slack-channel-id D0123ABCDEF 2>&1)"; then
    st_bad "migrate refuses a DM id as an effort channel" "it accepted one"
  else
    case "$out" in
      *"DM conversation id"*) st_ok "migrate refuses a D... id, naming why" ;;
      *) st_bad "migrate refuses a D... id" "$out" ;;
    esac
  fi

  # Put the good file back for the remaining sections, and ADD A SECOND EFFORT.
  #
  # TWO EFFORTS, NOT ONE, AND THAT IS THE WHOLE POINT OF THIS FIXTURE.
  # `docker compose run` attaches the caller's stdin even with -T, so a compose
  # call inside `while read ... done < <(...)` SWALLOWS the rest of the loop's
  # input and every later iteration is silently skipped. onboard-targets.sh
  # documents this; clawctl reintroduced it and a real two-effort run reported
  # "1 effort(s) checked" with the second one silently gone. A one-effort fixture
  # cannot see that. This one can.
  TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" COMPLIANCE_CLAW_SECRET_DIR="$S" \
    bash "${root}/scripts/clawctl" migrate --name crm-soc2 --slack-channel-id C0SOC2AAA >/dev/null 2>&1
  cat >> "$E" <<'SECOND'

  - name: crm-hipaa
    system_id: 13c1f44e-b66d-417c-8604-4ac7b988b411
    framework_id: hipaa
    credential_ref: default
    slack_channel_id: C0HIPAABB
    targets:
      - name: simple-crm
        url: https://github.com/pretorin-ai/simple-crm.git
        ref: main
      - name: other
        url: https://example.com/other.git
SECOND
  if python3 "${root}/scripts/parse-efforts.py" validate "$E" >/dev/null 2>&1; then
    st_ok "a second effort sharing IDENTICAL targets is accepted"
  else
    st_bad "a second effort sharing identical targets is accepted"
  fi

  # ------------------------------------------------------------- credential
  st_head "2. credential add"

  if out="$(COMPLIANCE_CLAW_SECRET_DIR="$S" bash "${root}/scripts/clawctl" \
              credential add hipaa-key 2>&1)"; then
    st_ok "credential add creates the file"
  else
    st_bad "credential add creates the file" "$out"
  fi

  local cpath="${S}/pretorin/hipaa-key" mode
  mode="$(stat -c '%a' "$cpath" 2>/dev/null || stat -f '%Lp' "$cpath" 2>/dev/null || echo '?')"
  if [ "$(id -u)" = 1000 ]; then
    [ "$mode" = 600 ] && st_ok "mode is 600 (host uid IS 1000)" || st_bad "mode" "got $mode"
  else
    # THE FOOTGUN THIS SUBCOMMAND EXISTS FOR. Compose file secrets are bind
    # mounts and cannot remap uid; a 0600 file is unreadable by the container's
    # uid-1000 user, and the symptom is an auth error that blames the key.
    [ "$mode" = 604 ] && st_ok "mode is 604 — readable by the container's uid-1000 user" \
                      || st_bad "mode is 604 (container-readable)" "got $mode"
  fi

  # THE DIRECTORY MODE IS HALF THE CONTRACT, AND THE HALF THAT HIDES.
  # compose.efforts.yaml mounts the credentials DIRECTORY whole, so the container's
  # uid-1000 user needs traverse on it as well as read on the file. A 0700
  # directory makes every credential inside report "does not exist" — a permission
  # problem wearing a missing-file message. Docker Desktop masks it on macOS by
  # presenting mounts as owned by the container user; Linux does not, and CI is
  # where it surfaced.
  local dmode
  dmode="$(stat -c '%a' "${S}/pretorin" 2>/dev/null || stat -f '%Lp' "${S}/pretorin" 2>/dev/null || echo '?')"
  if [ "$(id -u)" = 1000 ]; then
    [ "$dmode" = 700 ] && st_ok "credential dir is 700 (host uid IS 1000)" \
                       || st_bad "credential dir mode" "got $dmode"
  else
    [ "$dmode" = 701 ] && st_ok "credential dir is 701 — traversable by the container's uid-1000 user" \
                       || st_bad "credential dir is 701 (container-traversable)" "got $dmode"
  fi

  [ -s "$cpath" ] && st_bad "the new credential is empty (no value invented)" \
                  || st_ok "the new credential is empty (no value invented)"

  # Write-if-absent: a second add must not clobber a pasted value.
  printf 'CANARY-VALUE' > "$cpath"
  COMPLIANCE_CLAW_SECRET_DIR="$S" bash "${root}/scripts/clawctl" credential add hipaa-key >/dev/null 2>&1
  if [ "$(cat "$cpath")" = "CANARY-VALUE" ]; then
    st_ok "a second credential add does NOT overwrite the value"
  else
    st_bad "a second credential add does NOT overwrite the value"
  fi

  if out="$(COMPLIANCE_CLAW_SECRET_DIR="$S" bash "${root}/scripts/clawctl" \
              credential add default 2>&1)"; then
    st_bad "credential add refuses the reserved name 'default'"
  else
    case "$out" in *RESERVED*) st_ok "credential add refuses the reserved name 'default'" ;;
                   *) st_bad "credential add refuses 'default' for the stated reason" "$out" ;; esac
  fi

  if COMPLIANCE_CLAW_SECRET_DIR="$S" bash "${root}/scripts/clawctl" \
       credential add '../escape' >/dev/null 2>&1; then
    st_bad "credential add refuses a traversal name"
  else
    st_ok "credential add refuses a traversal name"
  fi

  # ------------------------------------------------------- plan: no effects
  st_head "3. plan has no side effects"

  rm -f "$record"
  st_write_stub_docker "$bin" "$record" refuse
  before="$(st_manifest "$tmp")"
  out="$(PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
           COMPLIANCE_CLAW_SECRET_DIR="$S" \
           COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml \
           bash "${root}/scripts/clawctl" plan 2>&1 || true)"
  after="$(st_manifest "$tmp")"

  if [ ! -s "$record" ]; then
    st_ok "plan invoked docker ZERO times"
  else
    st_bad "plan invoked docker ZERO times" "$(head -3 "$record")"
  fi
  if [ "$before" = "$after" ]; then
    st_ok "plan changed nothing on disk"
  else
    st_bad "plan changed nothing on disk" "$(diff <(echo "$before") <(echo "$after") | head -5)"
  fi
  case "$out" in
    *"docker compose run"*) st_ok "plan printed the commands apply would run" ;;
    *) st_bad "plan printed the commands apply would run" "$(printf '%s' "$out" | tail -3)" ;;
  esac
  # PLAN RUNS APPLY'S PREREQUISITE CHECKS. Without this, plan reports success for
  # a configuration apply rejects on its first line — a plan that lies.
  plan_out="$(PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
                COMPLIANCE_CLAW_SECRET_DIR="$S" COMPOSE_FILE=compose.yaml \
                bash "${root}/scripts/clawctl" plan 2>&1 || true)"
  case "$plan_out" in
    *"not on the file-backed credential path"*)
      st_ok "plan REFUSES the legacy compose path, exactly as apply does" ;;
    *) st_bad "plan refuses the legacy compose path" "$(printf '%s' "$plan_out" | tail -3)" ;;
  esac
  # ...and still starts nothing while doing it.
  rm -f "$record"; st_write_stub_docker "$bin" "$record" refuse
  PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
    COMPLIANCE_CLAW_SECRET_DIR="$S" \
    COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml \
    bash "${root}/scripts/clawctl" plan >/dev/null 2>&1 || true
  [ ! -s "$record" ] \
    && st_ok "plan's prerequisite checks start no container either" \
    || st_bad "plan's prerequisite checks start no container" "$(head -2 "$record")"

  # EVERY effort, not just the first. See the two-effort fixture note above.
  if printf '%s' "$out" | grep -q 'effort crm-soc2' \
     && printf '%s' "$out" | grep -q 'effort crm-hipaa'; then
    st_ok "plan covers EVERY effort (no stdin-swallowed iteration)"
  else
    st_bad "plan covers every effort" "one of the two efforts is missing from the output"
  fi

  # ------------------------------------------- apply: command construction
  st_head "4. apply command construction"

  # apply needs the targets to look cloned, and a non-empty credential.
  mkdir -p "${tmp}/workspace/targets/simple-crm/.git" "${tmp}/workspace/targets/other/.git"
  printf 'CANARY-VALUE' > "${S}/pretorin-api-key"
  rm -f "$record"
  st_write_stub_docker "$bin" "$record" answer

  # clawctl cd's to REPO_ROOT, so the clone check would look at the real tree.
  # CC_TARGETS_DIR points it at the fixture instead — the real code path, a
  # throwaway tree.
  local applylog="${tmp}/apply.log"
  ( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
      COMPLIANCE_CLAW_SECRET_DIR="$S" \
      COMPOSE_FILE=compose.yaml:compose.secrets.yaml \
      CC_TARGETS_DIR="${tmp}/workspace/targets" \
      bash "${root}/scripts/clawctl" apply ) >"$applylog" 2>&1 || true

  local pretorin_calls
  pretorin_calls="$(grep -c ' cli pretorin ' "$record" 2>/dev/null || true)"
  pretorin_calls="${pretorin_calls:-0}"
  if [ "${pretorin_calls:-0}" -gt 0 ]; then
    st_ok "apply issued ${pretorin_calls} Pretorin command(s)"

    local missing_pin=0 missing_cred=0
    while IFS= read -r line; do
      case "$line" in
        *"PRETORIN_SYSTEM_ID="*) ;; *) missing_pin=$((missing_pin+1)) ;;
      esac
      case "$line" in
        *"PRETORIN_FRAMEWORK_ID="*) ;; *) missing_pin=$((missing_pin+1)) ;;
      esac
      case "$line" in
        *"PRETORIN_API_KEY_FILE="*) ;; *) missing_cred=$((missing_cred+1)) ;;
      esac
    done < <(grep ' cli pretorin ' "$record")

    [ "$missing_pin" = 0 ] \
      && st_ok "EVERY Pretorin invocation carries both scope pins" \
      || st_bad "EVERY Pretorin invocation carries both scope pins" "$missing_pin missing"
    [ "$missing_cred" = 0 ] \
      && st_ok "EVERY Pretorin invocation names the effort's credential file" \
      || st_bad "EVERY Pretorin invocation names the effort's credential file" "$missing_cred missing"

    # THE ONE THAT MATTERS MOST. Stored context is a single global and cannot
    # describe more than one effort; the whole architecture is that the effort
    # path never touches it.
    if grep -q 'context set' "$record"; then
      st_bad "NO invocation runs 'context set'" "$(grep 'context set' "$record" | head -1)"
    else
      st_ok "NO invocation runs 'context set' (stored context is untouched)"
    fi

    # BYTE-ACCURACY, IN THE DIRECTION THAT MATTERS.
    #
    # Every command clawctl PRINTS must be a command it actually RAN, verbatim.
    # Printing a line that differs from what runs is the lie that makes `plan`
    # worthless, so that is the assertion.
    #
    # NOT the reverse: ol_pcli_quiet issues reads it deliberately does not echo
    # (`--json preflight show`, piped into the artifact analyser), as the legacy
    # onboard-targets.sh always has.
    local drift=0 echoed=0 line
    while IFS= read -r line; do
      line="${line#*\$ }"
      case "$line" in docker*' cli pretorin '*) ;; *) continue ;; esac
      echoed=$((echoed + 1))
      grep -Fqx "$line" "$record" \
        || { drift=$((drift+1)); [ "$drift" = 1 ] && echo "        first drift: $line"; }
    done < "$applylog"
    if [ "$echoed" = 0 ]; then
      st_bad "apply echoed its Pretorin commands" "nothing matched in $applylog"
    elif [ "$drift" = 0 ]; then
      st_ok "all ${echoed} echoed command(s) are byte-identical to the argv issued"
    else
      st_bad "echoed commands are byte-identical to the argv issued" "$drift of $echoed differ"
    fi
  else
    st_bad "apply issued Pretorin commands" "$(tail -5 "$applylog")"
  fi

  # BOTH efforts must appear, with DIFFERENT framework pins. A compose call that
  # eats the loop's stdin makes the second one vanish silently.
  if grep -q 'PRETORIN_FRAMEWORK_ID=soc2' "$record" \
     && grep -q 'PRETORIN_FRAMEWORK_ID=hipaa' "$record"; then
    st_ok "apply ran BOTH efforts, each with its own framework pin"
  else
    st_bad "apply ran both efforts with their own pins" \
           "$(grep -o 'PRETORIN_FRAMEWORK_ID=[a-z0-9]*' "$record" | sort -u | tr '\n' ' ')"
  fi

  # The lock is taken before the first Pretorin command, and released after.
  if grep -q ' run -d ' "$record"; then
    st_ok "apply took the lock via a detached sidecar"
  else
    st_bad "apply took the lock via a detached sidecar"
  fi
  if grep -qE '^docker rm ' "$record"; then
    st_ok "apply released the lock on exit"
  else
    st_bad "apply released the lock on exit"
  fi
  if grep -q 'update.lock' "$record"; then
    st_ok "the lock is the EXISTING .update.lock, not a second namespace"
  else
    st_bad "the lock is the EXISTING .update.lock, not a second namespace"
  fi
  # flock semantics only: nothing may delete the lock FILE.
  if grep -qE 'rm -f .*update\.lock|unlink.*update\.lock' "$record"; then
    st_bad "no lock-file deletion (flock semantics only)"
  else
    st_ok "no lock-file deletion (flock semantics only)"
  fi

  # The audit record carries the credential NAME and never a value.
  if grep -q 'CC_AUDIT_LINE' "$record"; then
    st_ok "apply wrote an audit record"
  else
    st_bad "apply wrote an audit record"
  fi
  if grep -q 'CANARY-VALUE' "$record" || grep -q 'CANARY-VALUE' "$applylog"; then
    st_bad "NO credential value appears in any command or output"
  else
    st_ok "NO credential value appears in any command or output"
  fi

  # ------------------------------------------------- COMPOSE_FILE behaviour
  st_head "5. COMPOSE_FILE: append the overlay, refuse the fork"

  rm -f "$record"
  st_write_stub_docker "$bin" "$record" answer
  out="$( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
            COMPLIANCE_CLAW_SECRET_DIR="$S" CC_TARGETS_DIR="${tmp}/workspace/targets" \
            COMPOSE_FILE=compose.yaml \
            bash "${root}/scripts/clawctl" apply 2>&1 || true )"
  case "$out" in
    *"not on the file-backed credential path"*)
      st_ok "legacy .env path is REFUSED (a real fork, not an omission)" ;;
    *) st_bad "legacy .env path is refused" "$(printf '%s' "$out" | head -3)" ;;
  esac
  case "$out" in
    *"compose.secrets.yaml"*) st_ok "the refusal prints the export line to paste" ;;
    *) st_bad "the refusal prints the export line to paste" ;;
  esac

  out="$( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
            COMPLIANCE_CLAW_SECRET_DIR="$S" CC_TARGETS_DIR="${tmp}/workspace/targets" \
            COMPOSE_FILE=compose.yaml:compose.secrets.yaml \
            bash "${root}/scripts/clawctl" apply 2>&1 || true )"
  case "$out" in
    *"appending it"*) st_ok "a missing compose.efforts.yaml is APPENDED, loudly" ;;
    *) st_bad "a missing compose.efforts.yaml is appended" "$(printf '%s' "$out" | head -3)" ;;
  esac
  case "$out" in
    *"export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml"*)
      st_ok "the effective COMPOSE_FILE line is printed for the operator to persist" ;;
    *) st_bad "the effective COMPOSE_FILE line is printed" ;;
  esac

  # -------------------------------------------------- validate: the pair check
  st_head "6. validate confirms the system+framework PAIR"

  rm -f "$record"
  st_write_stub_docker "$bin" "$record" answer "$root" "$E"

  # Both fixture efforts are framework f / hipaa. Report only 'f' as attached and
  # the hipaa effort must FAIL — a framework that exists is not enough, it has to
  # be attached to THIS system.
  out="$( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
            COMPLIANCE_CLAW_SECRET_DIR="$S" CC_TARGETS_DIR="${tmp}/workspace/targets" \
            COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml \
            STUB_ATTACHED="soc2" \
            bash "${root}/scripts/clawctl" validate 2>&1 || true )"
  case "$out" in
    *"is NOT attached to it"*) st_ok "an UNATTACHED framework FAILS the probe" ;;
    *) st_bad "an unattached framework fails the probe" "$(printf '%s' "$out" | tail -4)" ;;
  esac
  case "$out" in
    *"attached here: soc2"*) st_ok "the failure names what IS attached" ;;
    *) st_bad "the failure names what is attached" ;;
  esac

  # With both attached, both rows go green — the check is not simply always-fail.
  out="$( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
            COMPLIANCE_CLAW_SECRET_DIR="$S" CC_TARGETS_DIR="${tmp}/workspace/targets" \
            COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml \
            STUB_ATTACHED="soc2 hipaa" \
            bash "${root}/scripts/clawctl" validate 2>&1 || true )"
  if printf '%s' "$out" | grep -q 'all green'; then
    st_ok "with both frameworks attached, every row is green"
  else
    st_bad "with both attached, every row is green" "$(printf '%s' "$out" | tail -4)"
  fi

  # ------------------------------------------------- 7. the OpenClaw fleet
  #
  # The properties this section exists for, worst failure first:
  #
  #   - one agent per effort, each denying the OTHER efforts' MCP tools
  #   - exactly the declared Slack channels admitted AND bound, from one list
  #   - the configuration this deployment does not own comes out untouched
  #   - a re-apply of unchanged input changes nothing
  #   - an operator's DM binding survives
  #   - verification runs in the GATEWAY container, never in `cli`
  st_head "7. the OpenClaw fleet"

  local OC="${tmp}/openclaw.json"
  # A base configuration carrying things we must NOT touch. plugins.load.paths is
  # the array an earlier release silently emptied by naming it in a patch.
  cat > "$OC" <<'BASE'
{
  "gateway": { "mode": "local", "port": 18789, "bind": "lan" },
  "models": { "providers": { "openai": { "api": "openai-responses" } } },
  "agents": { "defaults": { "model": "gpt-5.5", "workspace": "/home/node/.openclaw/workspace" } },
  "tools": { "toolSearch": { "mode": "directory" } },
  "plugins": { "load": { "paths": ["/opt/compliance-claw/plugins/target-sync"] },
               "allow": ["slack", "pretorin-update", "target-sync"] },
  "mcp": { "servers": { "pretorin": { "command": "/home/node/.pretorin/bin/pretorin" } } },
  "channels": { "slack": { "enabled": true, "mode": "socket", "groupPolicy": "allowlist",
                           "dmPolicy": "disabled", "configWrites": false, "channels": {} } }
}
BASE

  rm -f "$record"
  st_write_stub_docker "$bin" "$record" answer
  local fleetlog="${tmp}/fleet.log"
  st_fleet_apply() {
    ( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
        COMPLIANCE_CLAW_SECRET_DIR="$S" \
        COMPOSE_FILE=compose.yaml:compose.secrets.yaml \
        CC_TARGETS_DIR="${tmp}/workspace/targets" CC_STATE_DIR="${tmp}/state" \
        STUB_OC_CONFIG="$OC" STUB_OC_FAIL="${1:-}" STUB_WS_ROOT="${tmp}/ocstate" \
        STUB_TARGETS="simple-crm other" STUB_ONBOARD="${2:-ok}" \
        STUB_WS_FAIL="${STUB_WS_FAIL:-}" \
        bash "${root}/scripts/clawctl" apply ) >"$fleetlog" 2>&1
  }
  st_fleet_apply || true

  # --- agents ---
  local q
  q() { CC_OC="$OC" python3 -c "
import json, os, sys
cfg = json.load(open(os.environ['CC_OC']))
$1" 2>/dev/null; }

  if [ "$(q "print(','.join(a['id'] for a in cfg['agents']['list']))")" = "crm-soc2,crm-hipaa" ]; then
    st_ok "two efforts produce two agents, named for the efforts"
  else
    st_bad "two efforts produce two agents" "$(q "print(cfg.get('agents'))")"
  fi
  if [ "$(q "print(cfg['agents']['list'][0].get('default'))")" = "True" ]; then
    st_ok "the first effort is the EXPLICIT default agent (not chosen by position)"
  else
    st_bad "the first effort is the explicit default agent"
  fi
  if [ "$(q "print(cfg['agents']['list'][0]['workspace'] != cfg['agents']['list'][1]['workspace'] and cfg['agents']['list'][0]['agentDir'] != cfg['agents']['list'][1]['agentDir'])")" = "True" ]; then
    st_ok "separate workspace AND agentDir (OpenClaw forbids sharing agentDir)"
  else
    st_bad "separate workspace and agentDir"
  fi

  # THE ISOLATION ASSERTION. Each agent denies the other's MCP tool prefix and
  # never its own — a deny naming its own prefix would silence the agent.
  if [ "$(q "print(cfg['agents']['list'][0]['tools']['deny'])")" = "['pretorin-crm-hipaa__*']" ] \
     && [ "$(q "print(cfg['agents']['list'][1]['tools']['deny'])")" = "['pretorin-crm-soc2__*']" ]; then
    st_ok "each agent denies the OTHER effort's MCP tool prefix, and only that"
  else
    st_bad "per-agent tool policy" "$(q "print([a.get('tools') for a in cfg['agents']['list']])")"
  fi

  # --- MCP ---
  if [ "$(q "print(sorted(cfg['mcp']['servers']))")" = "['pretorin-crm-hipaa', 'pretorin-crm-soc2']" ]; then
    st_ok "one named MCP server per effort, and the single-effort one is retired"
  else
    st_bad "MCP servers" "$(q "print(sorted(cfg['mcp']['servers']))")"
  fi
  if [ "$(q "
a=cfg['mcp']['servers']['pretorin-crm-soc2']; b=cfg['mcp']['servers']['pretorin-crm-hipaa']
print(a['command']==b['command'] and a['args']==['crm-soc2'] and b['args']==['crm-hipaa'])")" = "True" ]; then
    st_ok "both MCP servers run the SAME launcher with different effort names"
  else
    st_bad "MCP servers share one launcher binary"
  fi

  # --- Slack routing: the allowlist and the bindings come from one list ---
  if [ "$(q "
ch = sorted(cfg['channels']['slack']['channels'])
bd = sorted(b['match']['peer']['id'] for b in cfg['bindings'] if b['match']['peer']['kind']=='channel')
print(ch == bd == ['C0HIPAABB','C0SOC2AAA'])")" = "True" ]; then
    st_ok "the Slack allowlist and the channel bindings name exactly the same channels"
  else
    st_bad "allowlist and bindings agree" "$(q "print(sorted(cfg['channels']['slack']['channels']), cfg['bindings'])")"
  fi
  if [ "$(q "print(any(b['match']['peer']['kind']=='group' for b in cfg['bindings']))")" = "False" ]; then
    st_ok "NO speculative 'group' binding is emitted (MPIM is not supported here)"
  else
    st_bad "no group binding is emitted"
  fi
  if [ "$(q "print('dm' in cfg['channels']['slack'])")" = "False" ]; then
    st_ok "channels.slack.dm.* is never written (no MPIM admission machinery)"
  else
    st_bad "channels.slack.dm is untouched"
  fi
  if [ "$(q "print(cfg['channels']['slack']['dmPolicy'])")" = "disabled" ]; then
    st_ok "with no DM configured, dmPolicy stays 'disabled' and all DMs are blocked"
  else
    st_bad "DMs are disabled by default"
  fi

  # --- what we do NOT own survived ---
  if [ "$(q "print(cfg['plugins']['load']['paths'])")" = "['/opt/compliance-claw/plugins/target-sync']" ]; then
    st_ok "plugins.load.paths survived (the array an earlier release emptied)"
  else
    st_bad "plugins.load.paths survived" "$(q "print(cfg.get('plugins'))")"
  fi
  if [ "$(q "print(cfg['models']['providers']['openai']['api'], cfg['tools']['toolSearch']['mode'], cfg['gateway']['port'])")" = "openai-responses directory 18789" ]; then
    st_ok "unrelated models, tools and gateway configuration is untouched"
  else
    st_bad "unrelated configuration is untouched"
  fi

  # --- verification goes through the GATEWAY container, never `cli` ---
  #
  # This is a regression guard with a history: a check written on the `cli` path
  # could never have passed, because that container has its own empty loopback,
  # and it reported skip on every run instead of failing.
  if grep -q 'exec -T openclaw' "$record"; then
    st_ok "verification runs via 'compose exec -T openclaw'"
  else
    st_bad "verification runs in the gateway container" "no exec call was recorded"
  fi
  if grep -E 'exec -T openclaw' "$record" | grep -q 'openclaw_gateway_token'; then
    st_ok "  and re-reads the gateway token INSIDE the container"
  else
    st_bad "  and re-reads the gateway token inside the container" "$(grep 'exec -T' "$record" | head -2)"
  fi
  if grep -E 'run .*cli openclaw (health|agents|mcp)' "$record" >/dev/null 2>&1; then
    st_bad "no gateway-bound command is issued through the cli container" \
           "$(grep -E 'cli openclaw (health|agents|mcp)' "$record" | head -2)"
  else
    st_ok "  and NO gateway-bound command is issued through the cli container"
  fi
  if grep -q 'OPENCLAW_GATEWAY_TOKEN=[^"$]' "$record"; then
    st_bad "the token never appears in host argv" "$(grep -o 'OPENCLAW_GATEWAY_TOKEN=[^ ]*' "$record" | head -2)"
  else
    st_ok "  and the token value never appears in host argv"
  fi

  # --- the managed workspace, asserted on the FILES, not on the log ---
  #
  # The log line proves only that clawctl intended to write a workspace. What has
  # to be true is that the files exist and say the right thing — the bug this
  # replaced was a run that logged both workspaces and wrote neither.
  local WSA="${tmp}/ocstate/workspace-crm-soc2" WSB="${tmp}/ocstate/workspace-crm-hipaa"
  if [ -f "${WSA}/AGENTS.md" ] && [ -f "${WSB}/AGENTS.md" ]; then
    st_ok "a managed workspace with AGENTS.md exists for each effort"
  else
    st_bad "a managed workspace per effort" "no AGENTS.md under ${tmp}/ocstate"
  fi
  if grep -q "crm-soc2" "${WSA}/AGENTS.md" 2>/dev/null \
     && ! grep -q "crm-hipaa" "${WSA}/AGENTS.md" 2>/dev/null; then
    st_ok "  and each names ONLY its own effort"
  else
    st_bad "  and each names only its own effort" "$(head -20 "${WSA}/AGENTS.md" 2>/dev/null)"
  fi
  if grep -q "@EFFORT@\|@SYSTEM@\|@TARGET_LINES@" "${WSA}/AGENTS.md" 2>/dev/null; then
    st_bad "  no template placeholder survives into the generated file"
  else
    st_ok "  no template placeholder survives into the generated file"
  fi
  # The per-effort repository view: symlinks to the shared clones, and only the
  # targets this effort declares.
  if [ -L "${WSA}/targets/simple-crm" ] && [ -L "${WSA}/targets/other" ]; then
    st_ok "  the targets/ view holds a symlink per declared target"
  else
    st_bad "  the targets/ view holds a symlink per declared target" \
           "$(ls -l "${WSA}/targets" 2>&1 | head -4)"
  fi
  if [ "$(readlink "${WSA}/targets/simple-crm")" = "/workspace/targets/simple-crm" ]; then
    st_ok "  and each points at the ONE shared clone (not a copy)"
  else
    st_bad "  and each points at the one shared clone" "$(readlink "${WSA}/targets/simple-crm")"
  fi
  if grep -q "NOT A SANDBOX" "${WSA}/targets/README.md" 2>/dev/null; then
    st_ok "  and the view says plainly that it is not a boundary"
  else
    st_bad "  and the view says plainly that it is not a boundary"
  fi

  # STALE-ENTRY REMOVAL, AND THE FILES IT MUST NOT TOUCH. Only paths this tool
  # recorded last time are eligible; an operator's own file never is.
  printf 'operator notes\n' > "${WSA}/NOTES.md"
  ln -sf /workspace/targets/gone "${WSA}/targets/gone"
  printf 'targets/gone\ntargets/simple-crm\ntargets/other\ntargets/README.md\nAGENTS.md\n' \
    > "${WSA}/.compliance-claw-managed"
  st_fleet_apply || true
  if [ ! -e "${WSA}/targets/gone" ]; then
    st_ok "a managed entry that is no longer declared is removed"
  else
    st_bad "a managed entry no longer declared is removed" "targets/gone survived"
  fi
  if [ -f "${WSA}/NOTES.md" ]; then
    st_ok "  and an operator file in the same workspace is left alone"
  else
    st_bad "  and an operator file in the same workspace is left alone" "NOTES.md was deleted"
  fi

  # --- the last-applied record ---
  if [ -f "${tmp}/state/last-applied.json" ]; then
    st_ok "the last-applied record is written after verification passes"
  else
    st_bad "the last-applied record is written"
  fi
  if grep -q 'CANARY-VALUE' "${tmp}/state/last-applied.json" 2>/dev/null \
     || grep -qE 'pretorin-api-key|/run/secrets' "${tmp}/state/last-applied.json" 2>/dev/null; then
    st_bad "the record holds no credential value or path"
  else
    st_ok "the record holds no credential value and no credential path"
  fi

  # --- idempotence ---
  local sig_before sig_after
  sig_before="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  st_fleet_apply || true
  sig_after="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  if [ "$sig_before" = "$sig_after" ]; then
    st_ok "re-applying unchanged input changes nothing (idempotent)"
  else
    st_bad "re-applying unchanged input is idempotent" "$(diff <(echo "$sig_before") <(echo "$sig_after") | head -3)"
  fi

  # ------------------------------------------------- 8. DMs, and refusals
  st_head "8. Slack DMs"

  # An operator-created DM binding, as the Control UI would leave it.
  CC_OC="$OC" python3 -c "
import json, os
cfg = json.load(open(os.environ['CC_OC']))
cfg['bindings'].append({'agentId': 'crm-hipaa',
                        'match': {'channel': 'slack', 'peer': {'kind': 'direct', 'id': 'U0OPER123'}},
                        'session': {'dmScope': 'per-channel-peer'}})
cfg['channels']['slack']['allowFrom'] = ['U0OPER123']
cfg['channels']['slack']['dmPolicy'] = 'allowlist'
json.dump(cfg, open(os.environ['CC_OC'], 'w'), indent=2, sort_keys=True)
"
  st_fleet_apply || true
  if [ "$(q "print([b['agentId'] for b in cfg['bindings'] if b['match']['peer'].get('id')=='U0OPER123'])")" = "['crm-hipaa']" ]; then
    st_ok "an operator-created DM binding SURVIVES a later apply, unchanged"
  else
    st_bad "an operator DM binding survives apply" "$(q "print(cfg['bindings'])")"
  fi
  if [ "$(q "print(cfg['channels']['slack']['dmPolicy'], cfg['channels']['slack']['allowFrom'])")" = "allowlist ['U0OPER123']" ]; then
    st_ok "dmPolicy and allowFrom are DERIVED from the surviving binding"
  else
    st_bad "dmPolicy and allowFrom are derived"
  fi
  if [ "$(q "
ch = sorted(cfg['channels']['slack']['channels'])
print(ch == ['C0HIPAABB','C0SOC2AAA'])")" = "True" ]; then
    st_ok "  and the generated channel bindings are unaffected by it"
  else
    st_bad "channel bindings unaffected by a DM binding"
  fi

  # Two users, two sessions. Session isolation rides on the binding, so the
  # assertion is that each binding carries its own per-channel-peer scope.
  CC_OC="$OC" python3 -c "
import json, os
cfg = json.load(open(os.environ['CC_OC']))
cfg['bindings'].append({'agentId': 'crm-soc2',
                        'match': {'channel': 'slack', 'peer': {'kind': 'direct', 'id': 'U0SECOND1'}},
                        'session': {'dmScope': 'per-channel-peer'}})
cfg['channels']['slack']['allowFrom'] = ['U0OPER123', 'U0SECOND1']
json.dump(cfg, open(os.environ['CC_OC'], 'w'), indent=2, sort_keys=True)
"
  st_fleet_apply || true
  # Session isolation rides on the BINDING, not on a global: each direct binding
  # carries its own per-channel-peer scope, so two users never share a session.
  local scopes
  scopes="$(q "print(' '.join(sorted(b['match']['peer']['id'] + '=' + str(b.get('session',{}).get('dmScope')) for b in cfg['bindings'] if b['match']['peer']['kind']=='direct')))")"
  if [ "$scopes" = "U0OPER123=per-channel-peer U0SECOND1=per-channel-peer" ]; then
    st_ok "two allowed users keep two bindings, each with its own session scope"
  else
    st_bad "two allowed users have separate sessions" "$scopes"
  fi
  if [ "$(q "print('dmScope' in cfg.get('session', {}))")" = "False" ]; then
    st_ok "  and global session.dmScope is never written (nothing to fight over)"
  else
    st_bad "global session.dmScope is untouched"
  fi

  # --- the refusals ---
  st_dm_refuses() {
    local label="$1" expect="$2"
    local out; out="$(st_fleet_apply 2>&1 || true; cat "$fleetlog")"
    case "$out" in
      *"$expect"*) st_ok "refuses $label" ;;
      *) st_bad "refuses $label" "$(printf '%s' "$out" | tail -4)" ;;
    esac
  }

  st_oc_bindings() { CC_OC="$OC" CC_ADD="$1" python3 -c "
import json, os
cfg = json.load(open(os.environ['CC_OC']))
cfg['bindings'] = [b for b in cfg['bindings'] if b['match']['peer']['kind'] != 'direct']
cfg['bindings'].extend(json.loads(os.environ['CC_ADD']))
cfg['channels']['slack'].pop('allowFrom', None)
json.dump(cfg, open(os.environ['CC_OC'], 'w'), indent=2, sort_keys=True)
"; }

  st_oc_bindings '[{"agentId":"crm-soc2","match":{"channel":"slack","peer":{"kind":"direct","id":"U0DUP1234"}}},{"agentId":"crm-hipaa","match":{"channel":"slack","peer":{"kind":"direct","id":"U0DUP1234"}}}]'
  st_dm_refuses "one user bound to two efforts" "is bound twice"

  st_oc_bindings '[{"agentId":"retired-effort","match":{"channel":"slack","peer":{"kind":"direct","id":"U0GHOST12"}}}]'
  st_dm_refuses "a DM binding to an agent that no longer exists" "no longer exists"

  st_oc_bindings '[{"agentId":"crm-soc2","match":{"channel":"slack","peer":{"kind":"direct","id":"D0123ABCD"}}}]'
  st_dm_refuses "a DM binding using a D... conversation id" "not a Slack USER id"

  st_oc_bindings '[]'
  CC_OC="$OC" python3 -c "
import json, os
cfg = json.load(open(os.environ['CC_OC']))
cfg['channels']['slack']['allowFrom'] = ['U0UNBOUND']
json.dump(cfg, open(os.environ['CC_OC'], 'w'), indent=2, sort_keys=True)
"
  st_dm_refuses "an allowFrom entry with no binding (it would reach the default agent)" \
                "routes the DM to the default agent"

  st_oc_bindings '[]'
  CC_OC="$OC" python3 -c "
import json, os
cfg = json.load(open(os.environ['CC_OC']))
cfg['channels']['slack']['allowFrom'] = ['*']
json.dump(cfg, open(os.environ['CC_OC'], 'w'), indent=2, sort_keys=True)
"
  st_dm_refuses "a wildcard in allowFrom" "A wildcard admits every Slack user"

  # ------------------------------------------- 9. --effort, and rollback
  st_head "9. refusals that protect the fleet"

  # --effort would emit a one-effort agents.list and bindings array, which
  # REMOVES every other agent. It is refused rather than honoured.
  rm -f "$record"
  local before_state; before_state="$(st_manifest "$tmp")"
  for verb in plan apply; do
    out="$( ( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
              COMPLIANCE_CLAW_SECRET_DIR="$S" CC_STATE_DIR="${tmp}/state" \
              COMPOSE_FILE=compose.yaml:compose.secrets.yaml \
              bash "${root}/scripts/clawctl" "$verb" --effort crm-soc2 2>&1 || true ) )"
    case "$out" in
      *"REMOVES every other agent"*) st_ok "'${verb} --effort' is refused, naming what it would delete" ;;
      *) st_bad "'${verb} --effort' is refused" "$(printf '%s' "$out" | tail -3)" ;;
    esac
  done
  if [ "$(grep -c . "$record" 2>/dev/null || echo 0)" = 0 ]; then
    st_ok "  and the refusal starts no container at all"
  else
    st_bad "the refusal starts no container" "$(head -2 "$record")"
  fi
  if [ "$before_state" = "$(st_manifest "$tmp")" ]; then
    st_ok "  and changes nothing on disk"
  else
    st_bad "the refusal changes nothing on disk"
  fi

  # --- rollback ---
  st_oc_bindings '[]'
  st_fleet_apply || true
  local good; good="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"

  # Verification fails -> the previous configuration is restored, and the command
  # exits non-zero rather than reporting a success it cannot stand behind.
  # THE STATE, NOT THE LOG LINE. A "restoring..." message proves only that the
  # rollback branch was reached; both halves are captured before and compared after.
  local pre_cfg pre_ws
  pre_cfg="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  pre_ws="$(cat "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md" 2>/dev/null | head -3)"

  if st_fleet_apply verify; then
    st_bad "a verification failure fails the command" "apply exited 0"
  else
    st_ok "a verification failure fails the command (non-zero exit)"
  fi
  local post_cfg
  post_cfg="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  if [ "$post_cfg" = "$pre_cfg" ]; then
    st_ok "  and the CONFIGURATION is byte-identical to the pre-apply state"
  else
    st_bad "  and the configuration is byte-identical to the pre-apply state" \
           "post is ${#post_cfg} bytes, pre is ${#pre_cfg}; raw file $(wc -c < "$OC" 2>/dev/null) bytes"
  fi
  if [ "$(head -3 "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md" 2>/dev/null)" = "$pre_ws" ]; then
    st_ok "  and the MANAGED WORKSPACE is back too (both halves of the transaction)"
  else
    st_bad "  and the managed workspace is back too" "AGENTS.md differs after rollback"
  fi
  case "$(cat "$fleetlog")" in
    *"Pretorin onboarding is NOT part of this rollback"*)
      st_ok "  and the rollback says what it did NOT undo (platform onboarding)" ;;
    *) st_bad "  and the rollback says what it did not undo" "$(tail -4 "$fleetlog")" ;;
  esac

  # THE ROLLBACK ITSELF FAILING. The one case where this command genuinely does
  # not know what state the deployment is in — so it must say so and hand over
  # exact commands, not a summary that sounds like recovery happened.
  st_fleet_apply rollback && st_bad "a failed ROLLBACK fails the command" "it exited 0" \
                          || st_ok "a failed ROLLBACK fails the command (non-zero exit)"
  case "$(cat "$fleetlog")" in
    *"RESTORE DID NOT FULLY SUCCEED"*) st_ok "  and says plainly that the restore failed" ;;
    *) st_bad "  and says plainly that the restore failed" "$(tail -5 "$fleetlog")" ;;
  esac
  # It names the snapshots and stops there. It deliberately does NOT hand over a
  # command that removes or overwrites files in a volume holding operator notes.
  case "$(cat "$fleetlog")" in
    *"configuration: /home/node/.openclaw/openclaw.json.pre-apply."*)
      st_ok "  and names the exact configuration snapshot to recover from" ;;
    *) st_bad "  and names the configuration snapshot" "$(tail -8 "$fleetlog")" ;;
  esac
  case "$(cat "$fleetlog")" in
    *"rm -rf"*|*"tar -"*)
      st_bad "  and hands over no destructive command" \
             "$(grep -nE 'rm -rf|tar -' "$fleetlog" | head -3)" ;;
    *) st_ok "  and hands over no destructive command" ;;
  esac
  st_fleet_apply || true                # back to a good state

  # A patch that fails to apply must leave the runtime untouched.
  st_fleet_apply patch || true
  # WORDING, PRECISELY. "nothing was applied" would be a lie: Pretorin onboarding
  # runs before this point and may already have bound resolvers on the platform.
  # The message has to separate what was reverted from what stands.
  case "$(cat "$fleetlog")" in
    *"are back as they were"*)
      st_ok "a failed patch says both halves were put back" ;;
    *) st_bad "a failed patch says both halves were put back" "$(tail -4 "$fleetlog")" ;;
  esac
  case "$(cat "$fleetlog")" in
    *"bound on the platform"*)
      st_ok "  and does NOT claim nothing happened — onboarding may already stand" ;;
    *) st_bad "  and does not claim nothing happened" "$(tail -4 "$fleetlog")" ;;
  esac

  # ------------------------------- 10. a failed effort stops the whole fleet
  #
  # An effort that did not complete must not come out holding an agent, MCP server,
  # Slack binding and workspace. The old code set rc=1, said "skipping", and
  # generated the complete fleet anyway.
  st_head "10. a failed effort aborts fleet generation"

  st_oc_bindings '[]'
  st_fleet_apply || true              # a good run, for a known-good baseline
  local base_cfg base_state
  base_cfg="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  base_state="$(cat "${tmp}/state/last-applied.json" 2>/dev/null | tr -d ' \n')"

  # Comparing the config alone would be weak — a carried-on failure regenerates the
  # same fleet, so the file could look unchanged while every step ran. The workspace
  # and the last-applied record are what actually discriminate.
  rm -f "${OC}.snap"
  rm -rf "${tmp}/ocstate/workspace-crm-hipaa"

  # (a) ONBOARDING FAILS for both efforts.
  st_fleet_apply "" fail && st_bad "apply FAILS when onboarding fails" "it exited 0" \
                         || st_ok "apply FAILS when onboarding fails (non-zero exit)"
  case "$(cat "$fleetlog")" in
    *"did not complete"*) st_ok "  and names the effort(s) that did not complete" ;;
    *) st_bad "  and names the effort(s) that did not complete" "$(tail -4 "$fleetlog")" ;;
  esac
  local cfg_after_abort
  cfg_after_abort="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  if [ "$cfg_after_abort" = "$base_cfg" ]; then
    st_ok "  and the CONFIGURATION was never mutated"
  else
    st_bad "  and the configuration was never mutated" "it changed"
  fi
  local after_cfg
  after_cfg="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  if [ "$after_cfg" = "$base_cfg" ]; then
    st_ok "  and the CONFIGURATION is unchanged"
  else
    st_bad "  and the configuration is unchanged" "it changed"
  fi
  if [ ! -e "${tmp}/ocstate/workspace-crm-hipaa/AGENTS.md" ]; then
    st_ok "  and NO workspace was generated for the failed effort"
  else
    st_bad "  and no workspace was generated for the failed effort" "AGENTS.md appeared"
  fi
  if [ "$(cat "${tmp}/state/last-applied.json" 2>/dev/null | tr -d ' \n')" = "$base_state" ]; then
    st_ok "  and ${STATE_FILE##*/} was not rewritten"
  else
    st_bad "  and last-applied.json was not rewritten"
  fi
  # THE HONESTY CLAUSE. Onboarding runs per effort BEFORE any of this, so an
  # effort recorded as 'applied' really has been changed on the platform. Saying
  # "nothing was applied" here would be false.
  case "$(cat "$fleetlog")" in
    *"on the platform"*)
      st_ok "  and it is honest that earlier Pretorin onboarding may already stand" ;;
    *) st_bad "  and it is honest about earlier onboarding" "$(tail -6 "$fleetlog")" ;;
  esac
  case "$(cat "$fleetlog")" in
    *"Nothing was applied."*)
      st_bad "  and never says the bare 'Nothing was applied'" ;;
    *) st_ok "  and never says the bare 'Nothing was applied'" ;;
  esac

  # (b) A MISSING CREDENTIAL is the same class of failure and must abort too.
  mv "${S}/pretorin-api-key" "${S}/pretorin-api-key.aside"
  st_fleet_apply && st_bad "apply FAILS when a credential is missing" "it exited 0" \
                 || st_ok "apply FAILS when a credential is missing"
  case "$(cat "$fleetlog")" in
    *"no credential"*) st_ok "  and names the missing credential as the reason" ;;
    *) st_bad "  and names the missing credential" "$(tail -4 "$fleetlog")" ;;
  esac
  after_cfg="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  if [ "$after_cfg" = "$base_cfg" ]; then
    st_ok "  and again the configuration is untouched"
  else
    st_bad "  and again the configuration is untouched" "it changed"
  fi
  # An EMPTY credential file means "not configured" everywhere else; here too.
  : > "${S}/pretorin-api-key"
  st_fleet_apply && st_bad "apply FAILS when a credential file is EMPTY" "it exited 0" \
                 || st_ok "apply FAILS when a credential file is EMPTY"
  mv "${S}/pretorin-api-key.aside" "${S}/pretorin-api-key"
  st_fleet_apply || true              # restore a good state for anything after

  # ------------------------------- 11. the target-view collision refusal
  st_head "11. an operator file in the target view is never overwritten"

  # A file where a target symlink wants to go, which this tool did not create.
  rm -f "${tmp}/ocstate/workspace-crm-soc2/targets/simple-crm"
  printf 'operator wrote this\n' > "${tmp}/ocstate/workspace-crm-soc2/targets/simple-crm"
  grep -v '^targets/simple-crm$' "${tmp}/ocstate/workspace-crm-soc2/.compliance-claw-managed" \
    > "${tmp}/mf.tmp" && mv "${tmp}/mf.tmp" "${tmp}/ocstate/workspace-crm-soc2/.compliance-claw-managed"

  st_fleet_apply && st_bad "apply REFUSES to overwrite an operator file in targets/" "it exited 0" \
                 || st_ok "apply REFUSES to overwrite an operator file in targets/"
  case "$(cat "$fleetlog")" in
    *"targets/simple-crm"*) st_ok "  and names the exact path it will not touch" ;;
    *) st_bad "  and names the exact path" "$(tail -4 "$fleetlog")" ;;
  esac
  if [ "$(cat "${tmp}/ocstate/workspace-crm-soc2/targets/simple-crm")" = "operator wrote this" ]; then
    st_ok "  and the operator's file is still exactly as it was"
  else
    st_bad "  and the operator's file is still exactly as it was" "it was replaced"
  fi
  rm -f "${tmp}/ocstate/workspace-crm-soc2/targets/simple-crm"
  st_fleet_apply || true

  # ------------------ 11b. the workspace half of the transaction holds
  #
  # Three ways the workspace transaction can go wrong, each of which used to leave
  # the deployment in a state the command then described inaccurately.
  st_head "11b. the managed-workspace transaction"

  st_oc_bindings '[]'
  st_fleet_apply || true                        # known-good baseline
  local ws_base cfg_base state_base
  ws_base="$(head -3 "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md" 2>/dev/null)"
  cfg_base="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  state_base="$(cat "${tmp}/state/last-applied.json" 2>/dev/null | tr -d ' \n')"

  # (a) THE SNAPSHOT CANNOT BE WRITTEN. Without a backup there is nothing to roll
  #     back to, so the run must stop before touching anything at all.
  rm -f "${OC}.snap"
  STUB_WS_FAIL=snapshot st_fleet_apply \
    && st_bad "apply STOPS when the workspace snapshot cannot be written" "it exited 0" \
    || st_ok "apply STOPS when the workspace snapshot cannot be written"
  case "$(cat "$fleetlog")" in
    *"without a backup to return to"*) st_ok "  and says why it refused to proceed" ;;
    *) st_bad "  and says why it refused" "$(tail -4 "$fleetlog")" ;;
  esac
  # The config SNAPSHOT is a read and now runs first, deliberately; what must not
  # have happened is a mutation of the configuration itself.
  local cfg_ws_abort
  cfg_ws_abort="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  if [ "$cfg_ws_abort" = "$cfg_base" ]; then
    st_ok "  and the configuration was never mutated"
  else
    st_bad "  and the configuration was never mutated" "it changed"
  fi
  if [ "$(head -3 "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md" 2>/dev/null)" = "$ws_base" ]; then
    st_ok "  and no workspace was written"
  else
    st_bad "  and no workspace was written" "AGENTS.md changed"
  fi
  if [ "$(cat "${tmp}/state/last-applied.json" 2>/dev/null | tr -d ' \n')" = "$state_base" ]; then
    st_ok "  and last-applied.json is unchanged"
  else
    st_bad "  and last-applied.json is unchanged"
  fi

  # (b) EFFORT A IS WRITABLE, EFFORT B COLLIDES. The first workspace is rewritten
  #     before the second is even attempted, so a bare failure here would exit
  #     "unchanged" having changed one of them.
  printf 'MARKER-A\n' > "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md"
  rm -f "${tmp}/ocstate/workspace-crm-hipaa/targets/other"
  printf 'operator file\n' > "${tmp}/ocstate/workspace-crm-hipaa/targets/other"
  grep -v '^targets/other$' "${tmp}/ocstate/workspace-crm-hipaa/.compliance-claw-managed" \
    > "${tmp}/mf2.tmp" && mv "${tmp}/mf2.tmp" "${tmp}/ocstate/workspace-crm-hipaa/.compliance-claw-managed"

  st_fleet_apply && st_bad "apply FAILS when a later effort collides" "it exited 0" \
                 || st_ok "apply FAILS when a LATER effort collides"
  if [ "$(head -1 "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md")" = "MARKER-A" ]; then
    st_ok "  and the EARLIER effort's workspace was restored, not left rewritten"
  else
    st_bad "  and the earlier effort's workspace was restored" \
           "crm-soc2 AGENTS.md now starts: $(head -1 "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md")"
  fi
  if [ "$(cat "${tmp}/ocstate/workspace-crm-hipaa/targets/other")" = "operator file" ]; then
    st_ok "  and the operator's file is untouched"
  else
    st_bad "  and the operator's file is untouched"
  fi
  # Assigned first, not inlined into `[ ... ]`: the value is a multi-kilobyte JSON
  # document and the inline form trips the test builtin's argument handling.
  local cfg_now
  cfg_now="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  if [ "$cfg_now" = "$cfg_base" ]; then
    st_ok "  and the configuration never changed"
  else
    st_bad "  and the configuration never changed" "it differs from the baseline"
  fi
  rm -f "${tmp}/ocstate/workspace-crm-hipaa/targets/other"
  st_fleet_apply || true

  # (c) THE RESTORE FAILS during a rollback. A half-restored deployment must not
  #     be reported as "the workspaces are back".
  STUB_WS_FAIL=restore st_fleet_apply verify \
    && st_bad "a failed workspace RESTORE fails the command" "it exited 0" \
    || st_ok "a failed workspace RESTORE fails the command"
  case "$(cat "$fleetlog")" in
    *"managed WORKSPACES could NOT be restored"*)
      st_ok "  and does NOT claim the workspaces are back" ;;
    *) st_bad "  and does not claim the workspaces are back" "$(tail -5 "$fleetlog")" ;;
  esac
  case "$(cat "$fleetlog")" in
    *"workspaces:    /home/node/.openclaw/.compliance-claw-ws.pre-apply."*)
      st_ok "  and names the exact workspace snapshot to recover from" ;;
    *) st_bad "  and names the workspace snapshot" "$(tail -8 "$fleetlog")" ;;
  esac
  st_fleet_apply || true

  # --------------- 11c. the four remaining ways out of the transaction
  #
  # Each used to leave the deployment changed while the command said otherwise: a
  # failed copy became an empty "fresh" snapshot, a rejected patch died after the
  # workspaces were rewritten, a failed recreate skipped the rollback, and a failed
  # workspace restore skipped the config restore.
  st_head "11c. no escape from the transaction"

  st_oc_bindings '[]'
  st_fleet_apply || true
  local esc_cfg esc_ws
  esc_cfg="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
  printf 'MARKER-ESC\n' > "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md"
  esc_ws="MARKER-ESC"

  esc_unchanged() {   # $1 = label
    local now_cfg
    now_cfg="$(q "print(json.dumps({k:v for k,v in cfg.items() if k!='meta'}, sort_keys=True))")"
    if [ "$now_cfg" = "$esc_cfg" ] \
       && [ "$(head -1 "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md")" = "$esc_ws" ]; then
      st_ok "  ${1}: configuration AND workspace are exactly as before"
    else
      st_bad "  ${1}: configuration and workspace are exactly as before" \
             "cfg same=$([ "$now_cfg" = "$esc_cfg" ] && echo yes || echo no), ws first line=$(head -1 "${tmp}/ocstate/workspace-crm-soc2/AGENTS.md")"
    fi
  }

  # (a) THE CONFIG SNAPSHOT COPY FAILS. An empty snapshot would later be restored
  #     over a perfectly good configuration.
  st_fleet_apply cfgsnapshot && st_bad "apply STOPS when the config snapshot copy fails" "it exited 0" \
                             || st_ok "apply STOPS when the config snapshot copy fails"
  case "$(cat "$fleetlog")" in
    *"could not snapshot"*) st_ok "  and says the snapshot is what failed" ;;
    *) st_bad "  and says the snapshot is what failed" "$(tail -4 "$fleetlog")" ;;
  esac
  esc_unchanged "snapshot failure"

  # (b) THE DRY RUN FAILS. Validation is a read and now runs before any write.
  st_fleet_apply dryrun && st_bad "apply STOPS when the dry run rejects the patch" "it exited 0" \
                        || st_ok "apply STOPS when the dry run rejects the patch"
  case "$(cat "$fleetlog")" in
    *"did not validate"*) st_ok "  and says the patch is what was rejected" ;;
    *) st_bad "  and says the patch was rejected" "$(tail -4 "$fleetlog")" ;;
  esac
  esc_unchanged "dry-run failure"

  # (c) THE RECREATE FAILS after the patch is on disk. That must roll back, not die.
  st_fleet_apply restart && st_bad "a failed gateway recreate fails the command" "it exited 0" \
                         || st_ok "a failed gateway recreate fails the command"
  case "$(cat "$fleetlog")" in
    *"restoring what was there before"*)
      st_ok "  and rolls back rather than leaving the new configuration in place" ;;
    *) st_bad "  and rolls back" "$(tail -6 "$fleetlog")" ;;
  esac

  # (d) THE WORKSPACE RESTORE FAILS during rollback. The CONFIG restore must still
  #     be attempted — one half back beats neither.
  rm -f "${OC}.snap.probe"; cp "$OC" "${OC}.probe"
  st_fleet_apply2() {
    ( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
        COMPLIANCE_CLAW_SECRET_DIR="$S" COMPOSE_FILE=compose.yaml:compose.secrets.yaml \
        CC_TARGETS_DIR="${tmp}/workspace/targets" CC_STATE_DIR="${tmp}/state" \
        STUB_OC_CONFIG="$OC" STUB_OC_FAIL=verify STUB_WS_ROOT="${tmp}/ocstate" \
        STUB_TARGETS="simple-crm other" STUB_ONBOARD=ok STUB_WS_FAIL=restore \
        bash "${root}/scripts/clawctl" apply ) >"$fleetlog" 2>&1
  }
  st_fleet_apply2 && st_bad "a failed workspace restore fails the command" "it exited 0" \
                  || st_ok "a failed workspace restore fails the command"
  case "$(cat "$fleetlog")" in
    *"the CONFIGURATION was restored"*)
      st_ok "  and the CONFIG restore was still attempted, and succeeded" ;;
    *) st_bad "  and the config restore was still attempted" "$(tail -8 "$fleetlog")" ;;
  esac
  case "$(cat "$fleetlog")" in
    *"Both pre-apply snapshots are in the openclaw-state volume"*)
      st_ok "  and names both snapshots so the operator can recover by hand" ;;
    *) st_bad "  and names both snapshots" "$(tail -8 "$fleetlog")" ;;
  esac
  # NO DESTRUCTIVE COMMAND IS EVER PRINTED. The managed workspace paths sit beside
  # operator notes and SOUL.md, so a wildcard remove aimed at them is one typo away
  # from deleting the operator's own files.
  case "$(cat "$fleetlog")" in
    *"rm -rf"*|*"rm -f"*|*"tar -"*)
      st_bad "  and prints no command that deletes or overwrites anything" \
             "$(grep -nE 'rm -rf|rm -f|tar -' "$fleetlog" | head -3)" ;;
    *) st_ok "  and prints no command that deletes or overwrites anything" ;;
  esac
  rm -f "${OC}.probe"
  st_fleet_apply || true

  # (e) ROLLBACK ON A DEPLOYMENT THAT HAD NO CONFIG. The snapshot of "nothing" is
  #     an empty file; copying it back leaves a zero-byte openclaw.json that the
  #     entrypoint's never-clobber rule then preserves forever. The honest undo is
  #     to REMOVE what this run generated.
  rm -f "$OC" "${OC}.snap" "${tmp}/state/last-applied.json"
  st_fleet_apply verify && st_bad "a fresh-deployment apply that fails is rolled back" "it exited 0" \
                        || st_ok "a fresh-deployment apply that fails is rolled back"
  if [ -e "$OC" ]; then
    st_bad "  and the generated configuration is REMOVED, not left empty" \
           "openclaw.json still exists ($(wc -c < "$OC" | tr -d ' ') bytes)"
  else
    st_ok "  and the generated configuration is REMOVED, not left empty"
  fi
  case "$(cat "$fleetlog")" in
    *"no configuration existed yet"*)
      st_ok "  and the run said so up front rather than naming a snapshot to restore" ;;
    *) st_bad "  and the run said no configuration existed yet" "$(head -12 "$fleetlog")" ;;
  esac
  # Put the fixture back for the sections that follow.
  st_fleet_apply || true

  # ------------------------------- 12. plan reports removals
  st_head "12. plan reports what a removed effort would deactivate"

  # Drop the second effort from the file and ask plan what it would do. Plan reads
  # the host-side last-applied record rather than the volume, so this is also the
  # test that the record carries enough to report a removal at all.
  cp "$E" "${tmp}/efforts.both2.yaml"
  python3 - "$E" <<'PY'
import sys
src = open(sys.argv[1]).read()
open(sys.argv[1], "w").write(src.split("  - name: crm-hipaa")[0])
PY
  plan_out="$( ( cd "$tmp" && PATH="${bin}:$PATH" TARGETS_FILE="$T" CC_EFFORTS_FILE="$E" \
                 COMPLIANCE_CLAW_SECRET_DIR="$S" CC_STATE_DIR="${tmp}/state" \
                 COMPOSE_FILE=compose.yaml:compose.secrets.yaml \
                 bash "${root}/scripts/clawctl" plan 2>&1 || true ) )"
  case "$plan_out" in
    *"- agent crm-hipaa"*) st_ok "plan reports the removed agent" ;;
    *) st_bad "plan reports the removed agent" "$(printf '%s' "$plan_out" | grep -i agent | head -3)" ;;
  esac
  case "$plan_out" in
    *"- mcp pretorin-crm-hipaa (deactivated)"*)
      st_ok "  and reports its MCP server as deactivated" ;;
    *) st_bad "  and reports its MCP server as deactivated" \
              "$(printf '%s' "$plan_out" | grep -i mcp | head -3)" ;;
  esac
  case "$plan_out" in
    *"workspace, memory, credential and clones KEPT"*)
      st_ok "  and says removal is non-destructive" ;;
    *) st_bad "  and says removal is non-destructive" ;;
  esac
  cp "${tmp}/efforts.both2.yaml" "$E"

  # Keep the fixture on request, so a failure here can be inspected rather than
  # reproduced from scratch.
  if [ -n "${CC_KEEP_SELFTEST_TMP:-}" ]; then
    printf 'clawctl self-test: fixture kept at %s\n' "$tmp"
    ST_KEEP=1
  fi

  # ------------------------------------------------------------------ done
  printf '\n'
  printf 'clawctl self-test: %d pass, %d fail\n' "$ST_PASS" "$ST_FAIL"
  [ "${ST_KEEP:-0}" = 1 ] || rm -rf "$tmp"
  [ "$ST_FAIL" = 0 ] || return 1
  return 0
}
