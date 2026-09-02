#!/usr/bin/env bash
#
# onboard-lib.sh — the onboarding sequence, defined once, sourced by two callers.
#
#   scripts/onboard-targets.sh   the LEGACY single-effort path (targets.yaml).
#                                Unchanged behaviour, `context set` included.
#   scripts/clawctl              the effort-aware path. Env-pinned per effort,
#                                its own named credential, and NO `context set`
#                                anywhere.
#
# ORDER IS LOAD-BEARING: sweep, THEN bind.
#
#   `pretorin preflight unbind --name X` removes EVERY resolver named X, and
#   resolver names come from the directory basename — so a target's own
#   `<target>/docs` resolver and a stray `/app/docs` resolver are both called
#   "docs". Binding first and sweeping second would delete the legitimate one as
#   collateral. Sweeping first makes that impossible: the bind step re-creates
#   whatever belongs here, and nothing that belongs here exists yet when the
#   blunt instrument runs.
#
#   1. SWEEP             unbind foreign path resolvers, including /app
#   2. BIND              discover recommended local sources, then explicitly
#                        bind each declared target as a code_repository
#   3. verify            probe every resolver, persist results
#   4. provision --apply seed the active recipe set
#   5. ASSERT            per-resolver invariants, and no /app anywhere
#
# THE CALLER SUPPLIES:
#   OL_SYSTEM_ID     system id for this scope
#   OL_FRAMEWORK_ID  framework id for this scope
#   OL_TARGETS       bash array of target names
#   OL_LABEL         what to call this scope in messages
#   OL_RUN_ENV       bash array of extra `docker compose run` flags (may be empty).
#                    The effort path puts its -e PRETORIN_* pins and its
#                    -e PRETORIN_API_KEY_FILE here.
#   OL_DRY_RUN       1 to echo commands without running any (clawctl plan)
#
# WHY `plan` AND `apply` CANNOT DIVERGE. Both go through ol_pcli, which renders
# the command from the SAME arrays it then executes. The printed line is not a
# description of the command; it is the command. A `plan` that drifts from
# `apply` would be worse than no plan at all, so the only way to make them
# disagree is to change the renderer, which changes both.

# shellcheck shell=bash

OL_MOUNT="/workspace/targets"
OL_ARTIFACT_PY="${OL_ARTIFACT_PY:-scripts/preflight-artifact.py}"

ol_log()  { printf 'onboard: %s\n' "$*"; }
ol_warn() { printf 'onboard: WARNING — %s\n' "$*" >&2; }
ol_die()  { printf 'onboard: ERROR — %s\n' "$*" >&2; exit 1; }

# Render exactly what will run, shell-quoted so it can be pasted back.
ol_render() {
  local out="docker compose run --rm -T"
  local a
  for a in ${OL_RUN_ENV[@]+"${OL_RUN_ENV[@]}"}; do
    out="${out} $(printf '%q' "$a")"
  done
  out="${out} cli pretorin"
  for a in "$@"; do
    out="${out} $(printf '%q' "$a")"
  done
  printf '%s' "$out"
}

# Echo the command, then run it — unless OL_DRY_RUN.
#
# `< /dev/null` is not decoration. These run inside `while read ... done < <(...)`
# loops, and `docker compose run` attaches the caller's stdin even with -T — so
# without it the first container swallows the rest of the loop's input and every
# later iteration is silently skipped. That is exactly how the sweep first
# shipped unbinding only one of two foreign resolvers.
ol_pcli() {
  printf '  $ %s\n' "$(ol_render "$@")" >&2
  [ "${OL_DRY_RUN:-0}" = 1 ] && return 0
  docker compose run --rm -T ${OL_RUN_ENV[@]+"${OL_RUN_ENV[@]}"} cli pretorin "$@" < /dev/null
}

# Same command, no echo, stdout captured by the caller.
ol_pcli_quiet() {
  docker compose run --rm -T ${OL_RUN_ENV[@]+"${OL_RUN_ENV[@]}"} cli pretorin "$@" < /dev/null
}

ol_scope_args() { printf '%s\n' --system "$OL_SYSTEM_ID" --framework "$OL_FRAMEWORK_ID"; }

# --- 1. sweep --------------------------------------------------------------

ol_sweep() {
  local scope=(--system "$OL_SYSTEM_ID" --framework "$OL_FRAMEWORK_ID")
  ol_log "sweeping resolvers whose params.path is outside ${OL_MOUNT}"
  if [ "${OL_DRY_RUN:-0}" = 1 ]; then
    printf '  $ %s\n' "$(ol_render --json preflight show "${scope[@]}")" >&2
    ol_log "  then one 'preflight unbind <kind> --name <name>' per foreign resolver"
    ol_log "  (the list depends on that artifact, which plan does not read)"
    return 0
  fi
  local swept=0 kind rname
  while IFS=$'\t' read -r kind rname; do
    [ -n "${kind:-}" ] || continue
    ol_log "  unbinding ${kind} resolver '${rname}' (foreign path)"
    # Exits 1 when the name is already gone, which is success for our purposes.
    ol_pcli preflight unbind "$kind" --name "$rname" "${scope[@]}" >/dev/null 2>&1 || true
    swept=$((swept + 1))
  done < <(ol_pcli_quiet --json preflight show "${scope[@]}" 2>/dev/null \
             | python3 "$OL_ARTIFACT_PY" sweep)
  ol_log "  swept ${swept} foreign resolver name(s)"
}

# --- 2. bind ---------------------------------------------------------------

ol_bind() {
  local scope=(--system "$OL_SYSTEM_ID" --framework "$OL_FRAMEWORK_ID")
  local name path
  for name in "${OL_TARGETS[@]}"; do
    ol_log "binding ${name}"
    path="${OL_MOUNT}/${name}"
    # Keep discovery for every other source kind the framework recommends.
    # --workspace is what makes it deterministic: without it Pretorin inspects
    # the process's CURRENT DIRECTORY. Never --replace: it would wipe target
    # N-1 when target N is discovered.
    ol_pcli preflight init --workspace "$path" "${scope[@]}" --no-verify

    # A platform profile may intentionally omit code_repository (CMMC L1 does),
    # in which case `preflight init` skips Git discovery. The target declaration
    # is still authoritative for this deployment, so replace its named local
    # resolver explicitly. `bind` appends; unbinding first is what makes a rerun
    # exactly-once without disturbing other targets or provider resolvers.
    ol_pcli preflight unbind code_repository --name "$name" "${scope[@]}" >/dev/null || true
    ol_pcli preflight bind code_repository \
      --type workspace_path \
      --name "$name" \
      --constraint "Local repository and git metadata only; remote governance is verified separately." \
      --scope "workspace=${path}" \
      --param "path=${path}" \
      --param marker=.git \
      --capability repository_inventory \
      --capability source_configuration \
      --capability commit_history \
      "${scope[@]}"
  done
}

# --- 3 + 4. verify, provision ---------------------------------------------

ol_verify() {
  local scope=(--system "$OL_SYSTEM_ID" --framework "$OL_FRAMEWORK_ID")
  ol_log "verifying resolvers (probes run locally, not on the platform)"
  ol_pcli preflight verify "${scope[@]}"
}

ol_provision() {
  local scope=(--system "$OL_SYSTEM_ID" --framework "$OL_FRAMEWORK_ID")
  ol_log "provisioning the active recipe set"
  # --apply seeds the active set from what is runnable here, replacing it. Trim
  # afterwards with `pretorin recipe deactivate <id>`. Unmapped source kinds are
  # reported as gaps and are expected for a repos-only deployment.
  ol_pcli preflight provision --apply "${scope[@]}"
}

# --- 5. assert -------------------------------------------------------------

ol_assert() {
  local scope=(--system "$OL_SYSTEM_ID" --framework "$OL_FRAMEWORK_ID")
  ol_log "asserting preflight state"
  if [ "${OL_DRY_RUN:-0}" = 1 ]; then
    printf '  $ %s\n' "$(ol_render --json preflight show "${scope[@]}")" >&2
    ol_log "  then: python3 ${OL_ARTIFACT_PY} assert ${OL_TARGETS[*]}"
    return 0
  fi
  if ! ol_pcli_quiet --json preflight show "${scope[@]}" \
       | python3 "$OL_ARTIFACT_PY" assert "${OL_TARGETS[@]}"; then
    return 1
  fi
  ol_log "preflight state matches ${OL_LABEL}"
}

# --- the whole sequence ----------------------------------------------------

ol_onboard() {
  ol_sweep
  ol_bind
  ol_verify
  ol_provision
  ol_assert
}
