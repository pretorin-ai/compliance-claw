# Phase 1 — Supply-chain-verified Pretorin binary

Goal: a `linux/amd64` Docker build stage that produces a **cryptographically verified** Pretorin
0.26.14 binary at a known path, plus the minimal scaffold that needs. Nothing from later phases.

**Status: IMPLEMENTED and validated.** Every file below exists and the whole chain has been executed
end-to-end in an amd64 container, including all tamper checks. Results are in "Validation" below.

## Established facts

**Source: `pretorin-ai/homebrew-tap` (PUBLIC).** All required assets download anonymously (HTTP 200,
plain `curl`, no token) and are **byte-identical** to the private `pretorin-ai/pretorin-cli`
release. `v0.26.14` is the tap's `Latest`. Net effect: **no credentials, no `gh`, no `jq`, no
BuildKit secret anywhere in the build.**

**Toolchain: cosign `v2.4.1`**, asset `cosign-linux-amd64`, SHA256
`8b24b946dd5809c6bd93de08033bcf6bc0ed7d336b7785787c080f574b89249b` — matching
`pretorin-cli tools/install-release-tools.sh`, and independently cross-checked against upstream's
`cosign_checksums.txt`. Staying on the v2.x line is also *required*, not merely conventional:
**cosign v3 removed `--signature` from `verify-blob`** (v3.1.2 is bundle-only), so v3 cannot verify
these releases at all.

**`--insecure-ignore-tlog=true` is required** — signing had the transparency log disabled.
`pretorin-cli tools/verify-release.sh` is authoritative here and uses exactly that flag; observed
working.

**amd64 only.** `SHA256SUMS` publishes just `linux-x86_64` and `macos-arm64` — there is **no
linux/arm64 artifact at all**, so multi-arch is blocked upstream rather than merely deferred. This
matches hosting OpenClaw on an amd64 cell.

Other verified details the plan depends on:

- Tag `v0.26.14`; binary asset `pretorin-0.26.14-linux-x86_64` (no `v` in the asset name).
- `vendor/cosign.pub` is a P-256 ECDSA key, SHA256
  `76ebd1120eaf795fffa6a3a92754cbfbaeb06afd1faef5b23f54eb4dfb7bc53b`, **byte-identical across
  v0.26.10 → v0.26.14** — a stable release key, not per-release. `vendor/README.md` is the
  authoritative record; never abbreviate this digest, since a partial value is indistinguishable
  from a rotated key.
- Chain verified independently of cosign: `openssl dgst -sha256 -verify` → `Verified OK`.
- The binary is **dynamically linked glibc** x86-64 → Debian-family base, not Alpine (Phase 2 note).

## Design

`fetch` and `verify` are separate scripts, both running **inside** the verify stage. The split isn't
ceremony — it's what makes the verifier a pure function of a directory, so the tamper checks exercise
the *real* verifier against tampered bytes. Fused, every build would pull fresh bytes from GitHub and
"corrupt the binary" would be untestable.

Both scripts follow the `pretorin-cli tools/` idiom so the two repos read alike: `set -euo pipefail`,
`curl -fsSL --retry 3 --retry-all-errors`, compare against a **pinned** digest never a downloaded
checksum file, and `install -m 0755` only *after* verification.

| File | Responsibility |
| --- | --- |
| `versions.env` | Single source of truth for every pin; the only file later phases edit to bump. |
| `.gitignore` | Ignores `.env`, `workspace/`, `dist/`, `tamper/`. |
| `.dockerignore` | Keeps `dist/`, `tamper/`, `.git` out of the build context (each staged copy is ~24 MB). |
| `.env.example` | Documents required runtime secrets (`PRETORIN_API_KEY=`, `OPENCLAW_GATEWAY_TOKEN=`), empty values. |
| `vendor/cosign.pub` | Committed trust anchor — the root of the whole chain. |
| `vendor/README.md` | Anchor provenance: both source URLs, SHA256, key type, cross-release stability, how to re-verify. |
| `scripts/fetch-pretorin.sh` | `curl` the 3 pinned assets into a target dir. Anonymous, no auth. |
| `scripts/verify-pretorin.sh` | Offline verifier over a target dir: signature → digest gates → install. |
| `Dockerfile` | Phase 1 contributes only the `pretorin-verify` stage; later phases add stages beside it. |
| `docs/plans/phase1.md` | This document. |

### Pins

`versions.env` is the file, and is deliberately not reproduced here — an inlined copy drifts and then
misleads about what is actually pinned. It holds `OPENCLAW_VERSION`, `PRETORIN_VERSION`, `MODEL`,
`PRETORIN_REPO`, `PRETORIN_TARGET`, `PRETORIN_SHA256`, and the cosign triplet
(`COSIGN_VERSION` / `COSIGN_ASSET` / `COSIGN_SHA256`).

Two pins that need explanation beyond their comments:

- **`PRETORIN_SHA256`** — defence in depth against signing-key compromise. See "Resolved" below.
- **`COSIGN_*`** — matches `pretorin-cli tools/install-release-tools.sh`, and the v2.x line is
  mandatory, not stylistic.

One documented carve-out: the base image digest lives on the Dockerfile's `FROM` line, because `FROM`
cannot read a sourced file. Both files say so, so a pin audit knows to look in two places.

Derived, never hardcoded: tag `v${PRETORIN_VERSION}`, asset
`pretorin-${PRETORIN_VERSION}-${PRETORIN_TARGET}`, base URL
`https://github.com/${PRETORIN_REPO}/releases/download/v${PRETORIN_VERSION}`.

## Ordered steps

**Step 1 — pinned cosign** (`pretorin-verify` stage, base
`debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd`, plus
`curl` + `ca-certificates`):

```dockerfile
RUN curl -fsSL --retry 3 --retry-all-errors -o /tmp/cosign \
      "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/${COSIGN_ASSET}" \
 && echo "${COSIGN_SHA256}  /tmp/cosign" | sha256sum -c - \
 && install -m 0755 /tmp/cosign /usr/local/bin/cosign && rm /tmp/cosign
```

Two Dockerfile details found by building it: **omit the `# syntax=docker/dockerfile:1` directive**
(it forces a frontend image pull that timed out here, and no BuildKit-only features are used), and
**don't put `--platform=linux/amd64` on `FROM`** — that trips the `FromPlatformFlagConstDisallowed`
lint. Pass `--platform linux/amd64` on the `docker build` command instead.

**Step 2 — fetch** (`scripts/fetch-pretorin.sh <dir>`, default `dist`): `curl -fsSL` each of
`${BINARY}`, `SHA256SUMS`, `SHA256SUMS.sig` from the base URL. `-f` is what turns an HTTP error into
a non-zero exit instead of a file full of HTML. `cosign.pub` is deliberately **not** fetched — the
anchor comes from `vendor/`, in-repo and reviewable; fetching it per-build would make the trust
anchor whatever the server served.

**Step 3 — verify the signature over `SHA256SUMS`** (`scripts/verify-pretorin.sh <dir>`). First gate:
until the signature is good, no line in `SHA256SUMS` is trustworthy.

```sh
cosign verify-blob --key vendor/cosign.pub --signature "${DIR}/SHA256SUMS.sig" \
  --insecure-ignore-tlog=true "${DIR}/SHA256SUMS"
```

**Step 4 — hash the file that is about to be installed, then gate it twice.** Upstream's
`verify-release.sh` can run bare `sha256sum -c SHA256SUMS` because it downloads *all* `pretorin-*`
assets; we stage one binary, so the 6-line manifest would fail on the absent five.

Crucially, the fix is **not** to feed `sha256sum -c` a single extracted line. A checksum line names
the file it describes, and `sha256sum` filenames may contain spaces, so a signed line reading
`<pinned-digest>  decoy  <binary>` makes `-c` verify a *decoy* while `${BINARY}` is what gets
installed — with every gate printing OK. This was not hypothetical: the first implementation had it,
and it was exploited end to end under a simulated key compromise (see "Validation", case 0). Hash the
bytes you are actually going to use:

```sh
actual="$(sha256_of "${DIR}/${BINARY}")"                       # the file we will install
[ "$actual" = "$PRETORIN_SHA256" ] || exit 1                    # gate A: our own pin
signed="$(awk -v b="$BINARY" 'NF==2 && $2==b {print $1}' "${DIR}/SHA256SUMS")"
[ -n "$signed" ]        || exit 1                               # no entry => substituted release
[ "$signed" = "$actual" ] || exit 1                             # gate B: the signed manifest
```

`awk` with an exact field comparison replaces `grep -E`, which had two problems: the version number's
dots were regex wildcards (so `pretorin-0X26Y14-linux-x86_64` matched), and `…-linux-x86_64` is a
prefix of `…-linux-x86_64.spdx.json`. `NF==2` is what rejects an embedded-space filename. The
`-n "$signed"` branch is also the rollback detector, and it reports rollback distinctly — under
`set -e` a bare `grep` with zero matches would have killed the script before any diagnostic printed.

**Step 5 — install** to `${INSTALL_DIR:-/usr/local/bin}/pretorin`. The override exists so the gate can
run as a non-root check on a dev host, mirroring upstream's `INSTALL_DIR`. Later stages consume it
with `COPY --from=pretorin-verify /usr/local/bin/pretorin /usr/local/bin/`.

## Tamper checks (the supply-chain validation gate)

```sh
docker build --platform linux/amd64 --target pretorin-verify -t cc-verify .
./scripts/fetch-pretorin.sh tamper     # no auth needed; also the reset between checks
```

No `--build-arg`: the Dockerfile sources `versions.env` itself, keeping one source of truth.

Each check runs the real verifier against the tampered directory and must exit non-zero. Re-run the
`fetch` line to reset.

```sh
V() { docker run --rm --platform linux/amd64 -v "$PWD/tamper:/work" cc-verify bash scripts/verify-pretorin.sh /work; echo "exit=$?"; }

# 1. Corrupt the binary → digest gate fails.
printf '\0' >> tamper/pretorin-0.26.14-linux-x86_64; V

# 2. Rewrite SHA256SUMS to match the corrupted binary → SIGNATURE gate fails first.
printf '\0' >> tamper/pretorin-0.26.14-linux-x86_64; python3 -c "import re,hashlib,pathlib;p=pathlib.Path('tamper/SHA256SUMS');b='pretorin-0.26.14-linux-x86_64';h=hashlib.sha256((p.parent/b).read_bytes()).hexdigest();p.write_text(re.sub(rf'^\w+  {re.escape(b)}\$',f'{h}  {b}',p.read_text(),flags=re.M))"; V

# 3. Swap in v0.26.13's real signature — same key, valid sig, wrong message → SIGNATURE gate fails.
curl -fsSL -o tamper/SHA256SUMS.sig https://github.com/pretorin-ai/homebrew-tap/releases/download/v0.26.13/SHA256SUMS.sig; V

# 4. Digest disagrees with the versions.env pin → PIN gate fails after a good signature.
sed 's/^PRETORIN_SHA256=.*/PRETORIN_SHA256=deadbeef/' versions.env > /tmp/badpin.env; docker run --rm --platform linux/amd64 -v "$PWD/tamper:/work" -v /tmp/badpin.env:/opt/compliance-claw/versions.env:ro cc-verify bash scripts/verify-pretorin.sh /work; echo "exit=$?"

# 5. Rollback: v0.26.13's real manifest AND real signature, so the signature is genuinely valid
#    but names no 0.26.14 binary → "no entry for" gate fails.
curl -fsSL -o tamper/SHA256SUMS https://github.com/pretorin-ai/homebrew-tap/releases/download/v0.26.13/SHA256SUMS; curl -fsSL -o tamper/SHA256SUMS.sig https://github.com/pretorin-ai/homebrew-tap/releases/download/v0.26.13/SHA256SUMS.sig; V
```

Check 2 proves the signature gate genuinely precedes the digest gate, so an attacker controlling both
the binary *and* the manifest still cannot pass. Checks 3 and 5 are stronger than random bytes —
signatures that really do verify under the trusted key, just over the wrong content. Checks 4 and 5
each exercise a gate no other check reaches, which is exactly how the case-0 bypass below stayed
hidden: no check had ever driven a manifest whose contents disagreed with the staged filenames.

## Validation — observed results

Run against the committed implementation, `debian:trixie-slim` + cosign v2.4.1,
`--platform linux/amd64` on Apple Silicon (qemu):

| Case | Exit | Observed |
| --- | --- | --- |
| In-build fetch + verify | **0** | `Verified OK` → matches pin → matches signed entry → `PRETORIN VERIFIED: 0.26.14` |
| `pretorin --version` | **0** | `pretorin version 0.26.14` |
| Baseline, mounted dir (control) | **0** | verifier passes over a mount, so tamper failures are the tamper |
| **0 — validly-signed malicious manifest** | **1** | `BLOCKED — no malicious payload installed` |
| 1 — corrupt binary | **1** | signature `Verified OK`, then `does not match the pin in versions.env` |
| 2 — rewrite `SHA256SUMS` | **1** | fails *at the signature step*: `invalid signature when validating ASN.1 encoded signature` |
| 3 — swap signature | **1** | fails at the signature step, same error |
| 4 — digest disagrees with pin | **1** | signature `Verified OK`, then pin mismatch with both digests printed |
| 5 — rollback (real 0.26.13 manifest + sig) | **1** | `Verified OK`, pin matches, then `signed SHA256SUMS contains no entry for …` |
| Reset (control) | **0** | passes again |

Case 2 landing on the signature step — before any digest output — is the empirical proof of gate
ordering. cosign emits an expected `WARNING: Skipping tlog verification…` on every run; harmless.

### Case 0 — a real bypass, found in review and fixed

The first implementation delegated the checksum gate to `sha256sum -c` on a single extracted line. To
test that honestly, a throwaway P-256 key stood in for a compromised signing key and signed a manifest
containing one line:

```
a2c55b5c…f2f74  decoy  pretorin-0.26.14-linux-x86_64
```

`dist/decoy  pretorin-0.26.14-linux-x86_64` was a pristine copy of the real binary; the actual
`dist/pretorin-0.26.14-linux-x86_64` contained `MALICIOUS-PAYLOAD`. Against the original code the run
printed `Verified OK`, `digest matches versions.env pin`, `decoy  pretorin-0.26.14-linux-x86_64: OK`
and `PRETORIN VERIFIED: 0.26.14`, exited **0**, and installed the malicious file. The `PRETORIN_SHA256`
gate — added specifically to survive key compromise — was defeated, because it verified a file nobody
was going to run.

The current code hashes `${DIR}/${BINARY}` directly and exits 1. Retained as a permanent regression
check; the harness lives in the session scratchpad, and reproducing it only needs `openssl` plus a
mounted substitute `vendor/cosign.pub`.

Two lessons worth carrying into later phases: verify the bytes you are about to *use*, not the bytes a
manifest points at; and a gate no test drives is not a gate.

**Build-context hygiene, verified directly.** With a canary `.env` present in the working tree, a
probe stage that copies the entire context saw only `versions.env`, `vendor/`, and `scripts/` — the
`.dockerignore` allowlist keeps `.env` and staged artifacts out of the context entirely, so no image
layer can contain them.

## Acceptance

All of the above: happy-path build succeeds, `pretorin --version` reports 0.26.14, every tamper check
exits non-zero with a clean reset, the build works from a clean clone with **no credentials
configured**, and no secret/token/`.env` reaches the build context, any image layer, or `git status`.

## Resolved

1. **`versions.env` pins the expected binary SHA256 — implemented.** Rollback was already covered by
   Step 4, so the gap this closes is specifically **signing-key compromise**: an attacker with the
   key can sign anything, and only a pinned digest catches that. It also matches the house rule in
   `install-release-tools.sh` — "the runtime NEVER trusts a downloaded checksum file — it compares
   the bytes against these PINNED values and fails closed." Cost is re-deriving the hash on a version
   bump, already upstream's documented workflow. Drop the pin and its check in
   `verify-pretorin.sh` if you'd rather not carry that.

## Accepted limitations

- **`ca-certificates` and `curl` are installed unpinned** via `apt-get install`, so builds are not
  byte-reproducible and the CA bundle — which anchors every TLS fetch in the build — is the one
  unpinned link in an otherwise fully pinned chain. Pinning exact Debian package versions trades this
  for builds that break whenever the mirror drops an old version, which is the worse failure mode at
  POC stage. Revisit if reproducibility becomes a requirement; a base image that already ships both
  is the cleaner fix.
- **`MODEL` lives in `versions.env`** though it is runtime config rather than a version pin, because
  the Phase 1 spec put it there. If `versions.env` accumulates more runtime settings, move them to
  `.env`/`.env.example` and keep this file to pins.
- **The 3-asset list is stated in both scripts.** Read as each script declaring its own
  preconditions rather than a shared list; worth extracting only if a phase adds a fourth asset.

## Open questions

1. **`OPENCLAW_VERSION=2026.7.1` is recorded but unverified** — I left OpenClaw alone per the
   "don't touch other repos" constraint. Phase 2 should confirm the tag and asset names.
2. **cosign v2.4.1 is 2 minor versions behind the v2 tip (v2.6.4)** and the v2 line will eventually
   go EOL. Matching the CLI repo is right for now. The real fix is upstream publishing a Sigstore
   bundle (`SHA256SUMS.sigstore.json`), which unlocks v3 — worth raising with whoever owns the
   release pipeline as a deprecation runway, not a Phase 1 blocker.
3. **Is the case-0 bypass class present in `pretorin-cli tools/verify-release.sh` too?** It runs bare
   `sha256sum -c SHA256SUMS` over a manifest it just verified, which is safe *there* because it
   downloads every asset the manifest names and installs nothing. Worth a look by that repo's owner
   regardless, since the pattern is only safe under those conditions.
