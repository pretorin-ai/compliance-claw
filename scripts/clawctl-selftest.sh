#!/usr/bin/env bash
#
# clawctl-selftest.sh — sourced by `scripts/clawctl --self-test`.
#
# NO CREDENTIALS, NO CONTAINERS, NO NETWORK. Every docker invocation is
# intercepted by a stub on PATH that RECORDS its argv, so the tests can assert on
# what clawctl would run rather than on what it says it would run.
#
# The three properties worth proving here:
#
#   1. migrate converts a real single-effort targets.yaml correctly, and refuses
#      cleanly the second time.
#   2. `plan` has NO side effects: not one docker invocation, and not one byte
#      changed anywhere on disk.
#   3. `apply` builds the right commands: the scope pin and the named credential
#      on EVERY Pretorin invocation, `context set` on NONE of them, and each
#      echoed line byte-identical to the argv actually issued.
#
# (3) is the one that would otherwise rot silently. A `plan` that drifts from
# `apply` is worse than no plan, and the only defence that survives refactoring
# is comparing the printed text against the recorded argv.

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
  mkdir -p "$dir"
  cat > "${dir}/docker" <<STUB
#!/usr/bin/env bash
STUB_ATTACHED="\${STUB_ATTACHED:-}"
# DRAIN STDIN, BECAUSE REAL \`docker compose run\` DOES.
#
# This is what makes the two-effort fixture meaningful. Compose attaches the
# caller's stdin even with -T, so an unguarded call inside
# \`while read ... done < <(...)\` eats the rest of the loop's input and every
# later iteration is silently skipped. A stub that ignored stdin could never
# reproduce that, and the first version of this file did not — it reported 38/38
# with the bug deliberately reintroduced. Now it consumes stdin exactly as
# compose does, so a missing \`< /dev/null\` makes the second effort vanish here
# too.
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
# preflight show -> an empty but VALID artifact, so the sweep finds nothing and
# the assert reports "onboarding has not run" rather than crashing the harness.
case " \$* " in
  *" preflight show "*) echo '{"kinds":[]}'; exit 0 ;;
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
              bash "${root}/scripts/clawctl" migrate --name crm-soc2 2>&1)"; then
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
       bash "${root}/scripts/clawctl" migrate --name crm-soc2 >/dev/null 2>&1; then
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
              bash "${root}/scripts/clawctl" migrate 2>&1)"; then
    st_bad "migrate refuses to derive an effort name" "it generated one"
  else
    case "$out" in
      *"--name"*) st_ok "migrate refuses to derive a name and names --name" ;;
      *) st_bad "migrate refuses to derive a name" "message did not mention --name" ;;
    esac
  fi
  [ -e "$E" ] && st_bad "the refused migrate wrote no file" || st_ok "the refused migrate wrote no file"

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
    bash "${root}/scripts/clawctl" migrate --name crm-soc2 >/dev/null 2>&1
  cat >> "$E" <<'SECOND'

  - name: crm-hipaa
    system_id: 13c1f44e-b66d-417c-8604-4ac7b988b411
    framework_id: hipaa
    credential_ref: default
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
    # NOT the reverse. ol_pcli_quiet issues reads it deliberately does not echo
    # (`--json preflight show`, whose stdout is piped into the artifact
    # analyser), exactly as the legacy onboard-targets.sh always has. Requiring
    # every issued command to be echoed would fail that by design, and changing
    # it would alter the legacy path's output.
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

  # ------------------------------------------------------------------ done
  printf '\n'
  printf 'clawctl self-test: %d pass, %d fail\n' "$ST_PASS" "$ST_FAIL"
  rm -rf "$tmp"
  [ "$ST_FAIL" = 0 ] || return 1
  return 0
}
