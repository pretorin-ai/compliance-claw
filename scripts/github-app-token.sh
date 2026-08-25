#!/usr/bin/env bash
#
# github-app-token.sh — mint a short-lived, read-only GitHub App installation
# token for exactly the private repositories named on the command line.
#
#   scripts/github-app-token.sh <output-file> <owner/repo> [<owner/repo> ...]
#
# HOST ONLY. This script, the private key it reads, and the token it writes never
# enter the container. scripts/bootstrap.sh uses the token to clone private
# targets into ./workspace/targets/, and the container sees only the resulting
# working tree over the existing read-only bind mount. That is the whole reason
# the key is a file on the host instead of a variable in .env: compose's env_file
# hands every .env value to the container and to `docker inspect`, so a key there
# would be a git credential inside the container by construction.
#
# The token is written to <output-file> with mode 600 and nothing else. It is
# never printed, never passed as a command-line argument, and never exported —
# argv and the environment are both readable by other processes on a shared host.
#
# Configuration (process environment wins; otherwise read from .env):
#   GITHUB_APP_ID                 required. Settings -> Developer settings ->
#                                 GitHub Apps -> your app -> App ID.
#   GITHUB_APP_PRIVATE_KEY_FILE   required. Path to the .pem you generated.
#   GITHUB_APP_INSTALLATION_ID    optional. Only needed when the App is installed
#                                 on more than one account.
#
# The App needs exactly one permission: Repository -> Contents -> Read-only.
# Do not grant write anywhere. Compliance Claw reviews code; it never pushes.
#
# Dependencies are the ones bootstrap already requires: bash, curl, openssl,
# python3 (stdlib only). No `gh`, no `jq`, no PyJWT.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${GITHUB_API_URL:-https://api.github.com}"
ACCEPT="Accept: application/vnd.github+json"
APIV="X-GitHub-Api-Version: 2022-11-28"

log()  { printf 'github-app: %s\n' "$*" >&2; }
die()  { printf 'github-app: ERROR — %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 2 ] || die "usage: $0 <output-file> <owner/repo> [<owner/repo> ...]"
OUT="$1"; shift
SLUGS=("$@")

# Prefer the process environment, fall back to .env. Deliberately NOT `source
# .env`: that file is operator-editable and sourcing it would execute whatever it
# contains.
env_val() {
  local name="$1" val
  eval "val=\${${name}:-}"
  if [ -z "$val" ] && [ -r .env ]; then
    val="$(grep -E "^${name}=" .env | head -1 | cut -d= -f2- | tr -d '\r' || true)"
  fi
  printf '%s' "$val"
}

APP_ID="$(env_val GITHUB_APP_ID)"
KEY_FILE="$(env_val GITHUB_APP_PRIVATE_KEY_FILE)"
INSTALL_ID="$(env_val GITHUB_APP_INSTALLATION_ID)"

[ -n "$APP_ID" ] || die "GITHUB_APP_ID is not set.
  A private target needs a read-only GitHub App. See README.md ('Private
  repositories'), then put the App ID in .env."
case "$APP_ID" in
  '' | *[!0-9]*) die "GITHUB_APP_ID must be numeric, got '${APP_ID}'.
  This is the App ID, not the Client ID and not the App name." ;;
esac
[ -n "$KEY_FILE" ] || die "GITHUB_APP_PRIVATE_KEY_FILE is not set.
  Generate a private key on the App's settings page, save the .pem outside git
  (the repo gitignores secrets/ and *.pem), and name its path in .env."
[ -r "$KEY_FILE" ] || die "cannot read the GitHub App private key at '${KEY_FILE}'.
  GITHUB_APP_PRIVATE_KEY_FILE must point at the .pem file you downloaded.
  Paths are relative to ${REPO_ROOT}."
openssl rsa -in "$KEY_FILE" -noout -check >/dev/null 2>&1 \
  || die "'${KEY_FILE}' is not a usable RSA private key.
  GitHub issues these as PEM (-----BEGIN RSA PRIVATE KEY-----). If you saved the
  App's public manifest or a certificate by mistake, download the key again."

# Warn rather than fail on a loose mode: the operator owns this file, and
# refusing to run would be worse than telling them.
KEY_MODE="$(stat -c '%a' "$KEY_FILE" 2>/dev/null || stat -f '%Lp' "$KEY_FILE" 2>/dev/null || echo '?')"
case "$KEY_MODE" in
  600 | 400 | '?') ;;
  *) log "WARNING — ${KEY_FILE} is mode ${KEY_MODE}; it is a private key. chmod 600 it." ;;
esac

# --- 1. app JWT -------------------------------------------------------------
# RS256 by hand, because there is no host-side built-in for this and the
# alternative is a Python or Node dependency the rest of the repo does not have.
# openssl is already a bootstrap requirement.

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

NOW="$(date +%s)"
# iat is backdated 60s so a host clock that runs slightly fast is still accepted;
# exp is 8 minutes out, which keeps BOTH windows GitHub can check inside its
# 10-minute limit — exp-now is 480s and exp-iat is 540s. Setting exp to NOW+540
# would make exp-iat exactly 600, i.e. sitting precisely on the boundary, which is
# a pointless risk for a token that only needs to live long enough for two calls.
HEADER="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
PAYLOAD="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 480))" "$APP_ID" | b64url)"
SIGNING_INPUT="${HEADER}.${PAYLOAD}"
SIG="$(printf '%s' "$SIGNING_INPUT" \
  | openssl dgst -sha256 -sign "$KEY_FILE" -binary \
  | b64url)"
JWT="${SIGNING_INPUT}.${SIG}"

gh_api() {
  # $1 method, $2 path, $3 auth header value, $4 optional body
  local method="$1" path="$2" auth="$3" body="${4:-}"
  if [ -n "$body" ]; then
    curl -fsSL --retry 3 --retry-all-errors -X "$method" \
      -H "Authorization: ${auth}" -H "$ACCEPT" -H "$APIV" \
      -d "$body" "${API}${path}"
  else
    curl -fsSL --retry 3 --retry-all-errors -X "$method" \
      -H "Authorization: ${auth}" -H "$ACCEPT" -H "$APIV" \
      "${API}${path}"
  fi
}

# --- 2. resolve the installation -------------------------------------------

if [ -z "$INSTALL_ID" ]; then
  INSTALLS="$(gh_api GET /app/installations "Bearer ${JWT}" || true)"
  [ -n "$INSTALLS" ] || die "the App JWT was rejected by ${API}/app/installations.
  Check GITHUB_APP_ID (${APP_ID}) matches the key in ${KEY_FILE}, and that your
  clock is correct — a JWT more than a minute fast is refused."
  INSTALL_ID="$(printf '%s' "$INSTALLS" | python3 -c '
import json, sys
items = json.load(sys.stdin)
if len(items) == 1:
    print(items[0]["id"])
else:
    for i in items:
        acct = (i.get("account") or {}).get("login", "?")
        sys.stderr.write("  installation %s on %s\n" % (i["id"], acct))
' 2>/tmp/gh-installs.$$)" || true
  if [ -z "$INSTALL_ID" ]; then
    log "the App is installed on 0 or several accounts, so the installation cannot be inferred:"
    cat /tmp/gh-installs.$$ >&2 2>/dev/null || true
    rm -f /tmp/gh-installs.$$
    die "set GITHUB_APP_INSTALLATION_ID in .env to the one you want.
  If the list above is empty, the App exists but is not installed anywhere yet:
  App settings -> Install App -> pick the account -> select the repositories."
  fi
  rm -f /tmp/gh-installs.$$
  log "installation ${INSTALL_ID} (discovered)"
else
  log "installation ${INSTALL_ID} (from GITHUB_APP_INSTALLATION_ID)"
fi

# --- 3. mint a down-scoped token -------------------------------------------
# The token is restricted to contents:read on exactly the repositories declared
# private in targets.yaml. That is the point: even if it leaked inside its one
# hour, it reaches nothing else in the org. `repositories` takes bare repository
# names, not owner/repo.

BODY="$(python3 - "${SLUGS[@]}" <<'PY'
import json, sys
names = []
for slug in sys.argv[1:]:
    if "/" not in slug:
        sys.stderr.write("github-app: ERROR - '%s' is not owner/repo\n" % slug)
        raise SystemExit(2)
    names.append(slug.split("/", 1)[1])
print(json.dumps({
    "repositories": names,
    "permissions": {"contents": "read", "metadata": "read"},
}))
PY
)"

log "requesting a read-only token for: ${SLUGS[*]}"
RESP="$(gh_api POST "/app/installations/${INSTALL_ID}/access_tokens" "Bearer ${JWT}" "$BODY" 2>/dev/null || true)"

if [ -z "$RESP" ]; then
  # The down-scoped request failed. The bare API error names neither the repo nor
  # the fix, so spend one extra call to say something useful. This broad token is
  # requested ONLY on the error path and is never written to disk.
  log "the scoped token request was refused. Working out which repository is missing..."
  BROAD="$(gh_api POST "/app/installations/${INSTALL_ID}/access_tokens" "Bearer ${JWT}" \
            '{"permissions":{"contents":"read","metadata":"read"}}' 2>/dev/null || true)"
  if [ -n "$BROAD" ]; then
    BTOK="$(printf '%s' "$BROAD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null || true)"
    if [ -n "$BTOK" ]; then
      HAVE="$(gh_api GET "/installation/repositories?per_page=100" "token ${BTOK}" 2>/dev/null \
              | python3 -c 'import json,sys; print(" ".join(r["full_name"] for r in json.load(sys.stdin)["repositories"]))' 2>/dev/null || true)"
      unset BTOK BROAD
      MISSING=""
      for s in "${SLUGS[@]}"; do
        case " $HAVE " in *" $s "*) ;; *) MISSING="${MISSING} ${s}" ;; esac
      done
      if [ -n "$MISSING" ]; then
        die "the GitHub App installation does not include:${MISSING}
  It currently covers: ${HAVE:-<nothing>}
  Add the missing repositories to the installation, then re-run:
    https://github.com/settings/installations/${INSTALL_ID}
  (organisation installs: Organisation settings -> GitHub Apps -> Configure)"
      fi
      die "every requested repository is in the installation, but the token
  request was still refused. The usual cause is a permission the App was never
  granted: it needs Repository -> Contents -> Read-only. Grant it, then accept
  the permission request on the installation page:
    https://github.com/settings/installations/${INSTALL_ID}"
    fi
  fi
  die "could not mint an installation token for installation ${INSTALL_ID}.
  Verify the App ID, the private key, and that the App is still installed."
fi

# --- 4. write it, and only it ---------------------------------------------

( umask 077 && printf '%s' "$RESP" \
    | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["token"])' > "$OUT" )
chmod 600 "$OUT"
[ -s "$OUT" ] || die "the token file ${OUT} is empty; refusing to report success."

EXPIRES="$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expires_at","?"))' 2>/dev/null || echo '?')"
log "token written to ${OUT} (mode 600), contents:read only, expires ${EXPIRES}"
