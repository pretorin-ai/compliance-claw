# Verifying the image you pulled

This guide is for the VM operator installing or updating a deployment. The
maintainer-side publication steps are in [releasing.md](releasing.md). Run
commands from the repository root.

**Pull by digest, not by tag.** A tag is a mutable pointer — the same
`:<version>` can be made to resolve to different bytes tomorrow. A digest is the
bytes: `@sha256:…` is a content address, so if it resolves at all, it resolves to
exactly the image that was built, smoked, scanned and inventoried by the release
run that produced it.

```sh
docker login ghcr.io          # the package is not public
docker pull ghcr.io/pretorin-ai/compliance-claw:<version>@sha256:<digest>
```

The pair this checkout deploys is in [compose.yaml](../compose.yaml) — copy it from
there rather than retyping a version seen in these examples.

The digest is printed in the release run's job summary, and `compose.yaml` carries
the line to paste it into. The release job also proves the round trip itself: it
deletes the local image, pulls the digest back from the registry, runs it, and
regenerates the SBOM from the pulled bytes to confirm the package inventory
matches the one taken from the build.

Check what you are actually running at any time:

```sh
docker compose images                      # what compose resolved
docker inspect --format '{{index .RepoDigests 0}}' \
  ghcr.io/pretorin-ai/compliance-claw:<version>@sha256:<digest>
```

The image also states its own version, set from the release tag at build time:

```sh
docker compose run --rm cli \
  grep '^IMAGE_VERSION=' /opt/compliance-claw/versions.env
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  ghcr.io/pretorin-ai/compliance-claw:<version>@sha256:<digest>
```

A local build reports `0.0.0-dev` (or `0.0.0-dev+<shortsha>` via
`scripts/bootstrap.sh --build`), never a release number — so an image built on
someone's laptop can never be mistaken for a published one.

## Checking a release set

Releases published by the
[release-set procedure](releasing.md#the-release-set) carry these assets:
`compliance-claw-release.json` (the release record), `compose.release.yaml` (an
overlay that selects the release digest for `openclaw` and `cli`),
`sbom-X.Y.Z.spdx.json`, and, for a signed release,
`compliance-claw-release.json.sig` (the record signature). A signed release also
has a cosign image signature beside its digest in the registry. Earlier releases
have only the SBOM. A draft release is a candidate, not a customer release.

The source tag `vX.Y.Z` can still pin the previous image in `compose.yaml`. That
pin moves only in the commit after the release. The release overlay is what
selects the release image for the tagged source.

**A published set is unsigned today.** Nothing proves who published it. For
that reason, `check` refuses every published release with exit 6, and the
customer install and update tools refuse it. The signature verifier below
exists, but no release key is committed and the release workflow does not sign.
Key integration and signing activation are pending
([#80](https://github.com/pretorin-ai/compliance-claw/issues/80)). Do not
install a release set by hand to work around this.

### What `check` verifies for a signed release

For a set whose record says `signature.status: signed`, `check` passes only when
all of these are true:

1. The record is final, canonical and valid, and every asset matches its
   recorded SHA-256 and size. The record binds the overlay and the SBOM, so a
   changed SBOM or overlay fails.
2. `release-keys/compliance-claw-release.pub` **in your checkout** is one valid
   ECDSA P-256 public key (OpenSSL checks it), and `signature.key_sha256` in the
   record is its fingerprint.
3. `compliance-claw-release.json.sig` verifies over the exact record bytes with
   that key (OpenSSL).
4. The image signature at the recorded digest verifies with the same key
   (`cosign verify --key … --insecure-ignore-tlog=true`), and every verified
   payload names exactly the recorded digest, image repository and signature
   type.
5. With `--source`, the checkout is at the recorded tag and commit.

A `signed` status alone proves nothing. A missing, altered, stale, malformed or
wrong-key record signature, a missing image signature, or an image signature
for another digest or repository exits 6. Any status other than `unsigned` or
`signed` exits 6. The key is never taken from a download, an option or the
environment.

The checks need:

- OpenSSL 1.1.1 or later (`openssl pkey -pubcheck`). An openssl without that
  option, for example LibreSSL, gets exit 5;
- for the image check, a Linux amd64 host (the deployment VM). Other hosts get
  exit 5;
- the cosign that [versions.env](../versions.env) pins. `check` downloads that
  exact file to a temporary file, compares it with `COSIGN_SHA256`, and keeps it
  in `.cache/release-tools/` (gitignored). It compares the cached file with the
  pin again on every use. A failed download, checksum or timeout exits 5;
- registry read access. cosign uses this host's existing registry login;
  `check` handles no credential. A registry that refuses access or cannot be
  reached exits 5.

`--record-only` checks everything except the image signature, and says
`image signature NOT checked here`. The install and update tools use it only
for later checks of a set that they already verified in full.

### First trust in the release key

The release key in your checkout is the root of this trust. A changed key in a
compromised checkout would make a forged release verify. Before the first
signed install or update, compare the key fingerprint with the one Pretorin
gives you through a channel separate from this repository. This command prints
a fingerprint only when OpenSSL accepts the key:

```sh
openssl pkey -pubin -in release-keys/compliance-claw-release.pub -pubcheck \
  -outform DER -out /tmp/cc-release-key.der && sha256sum /tmp/cc-release-key.der
```

Stop if the command fails or the fingerprints differ. After that, an update
checks a new release with the key of the checkout you already trust, never with
the key in the new tag. A key change in a later release is visible in its diff
of `release-keys/`.

### Inspect a published set

To inspect a published set without installing it, download it (no credential
is needed; the directory must be empty or absent) and check it against a
checkout of the release tag:

```sh
python3 scripts/release-assets.py fetch --version X.Y.Z --dir /tmp/cc-vX.Y.Z
python3 scripts/release-assets.py check --allow-unsigned --dir /tmp/cc-vX.Y.Z --version X.Y.Z --source .
```

`fetch` downloads the record, the overlay, the SBOM and, for a signed record,
the record signature. It checks the download integrity only and reports the
signature status.

`check` refuses a candidate or draft record, a changed or extended overlay, an
asset whose SHA-256 or size differs from the record, and a checkout whose tag or
`HEAD` is not the recorded commit. `--source . --tag-only` checks only that the
tag names the recorded commit, without a requirement for the checkout to be
there. `--allow-unsigned` admits the status `unsigned` only, and prints
`UNVERIFIED: publisher authenticity not checked`. It is for preparation,
preview and inspection of unsigned releases; customer install and apply never
use it, and it never relaxes a signed check.

### Selection

The verified record, its signature and the overlay belong in the repository
root, where all three names are gitignored. Select the overlay directly after
`compose.yaml`, so that secret, effort, customer, and restore overlays keep
their order and precedence:

```dotenv
COMPOSE_FILE=compose.yaml:compose.release.yaml:compose.secrets.yaml:compose.efforts.yaml
```

Then confirm what Compose will run (no daemon is needed). An unsigned set needs
`--allow-unsigned` for this inspection. For a signed set that was already
verified in full, `--record-only` skips only the repeated image check:

```sh
python3 scripts/release-assets.py check --allow-unsigned --compose
```

The check keeps the rendered Compose model in memory and prints only image
references. A legacy `.env` selection renders secret values into that model, so
do not save it to a file. A caller that already renders it can pipe it:
`docker compose --profile cli config --format json | python3 scripts/release-assets.py check --allow-unsigned --rendered -`.

| Exit | Meaning |
| --- | --- |
| 0 | The set is valid, a signed set's signatures verify (with `--record-only`: the record signature only), and with `--compose` the set is selected for both services. |
| 1 | The record, overlay, an asset, a checksum, the stage, or the version is invalid or does not match. |
| 3 | The checkout is not at the recorded commit, or the tag names another commit. |
| 4 | Compose selects another image: the overlay is not selected, or a later overlay (for example a restore overlay) sets `image`. The check prints the expected and effective references and changes nothing. |
| 5 | Git, Docker Compose, the download, or a signature tool cannot run (openssl missing or without `-pubcheck`; not Linux amd64; cosign download, checksum or timeout; no registry access), or the selection does not render. |
| 6 | The release is not signed, its signature status is unknown, or a signature does not verify with the key in this checkout. Customer install and apply refuse it. |

Exit 2 is a usage error.

`scripts/update.sh --release vX.Y.Z --preview` downloads and checks a release
set without a change; apply installs it after the checks in
[Routine deployment update](upgrade.md#routine-deployment-update). Apply
refuses an unsigned release set, so today it refuses every release. While
`compose.release.yaml` is selected, it keeps selecting its own release. `scripts/bootstrap.sh` and `scripts/smoke.sh`
report the selected image, not the base pin.

## What this does and does not prove

> **The image is not signed.** There is no signature to verify, so do not reach for
> `cosign verify` — it will not find anything. A digest gives **integrity**: these
> exact bytes, not some other bytes wearing the same tag. It does not give
> **authenticity** — it is no proof of *who* built the image. Anyone who can push
> to the registry can publish a different digest, and a digest alone does not tell
> you which one came from this repository's release workflow.

The image's current integrity controls, in full:

| Control | What it gives you |
| --- | --- |
| GHCR image pinned by **immutable digest** | the bytes are the bytes that were built and scanned |
| **SBOM** generated per release (SPDX JSON) | a package inventory, retained as a workflow artifact on the release run |
| **Vulnerability scan** at release | fixable HIGH and CRITICAL findings block publication, except the findings inherited from the official upstream image that [.trivyignore.yaml](../.trivyignore.yaml) lists; those stay in the report |
| **Release record** with asset checksums | the source commit, version, digest, overlay, and SBOM belong together |
| Documented release provenance | the workflow, the digest, and the version pin are all recorded |

The SBOM is not attached to the OCI image and is not signed. It is available
as a workflow artifact and as an asset on the GitHub Release. See the
[release procedure](releasing.md).

An unsigned record binds files without proving publisher identity. The default
check refuses it (exit 6); see [release-set checks](#checking-a-release-set).

For a signed release, a verified signature would prove that the holder of the
release key signed exactly that record (which binds the source commit, the
overlay and the SBOM hash) and that digest. It would not prove that the key in
your checkout is the right key; the
[first-trust comparison](#first-trust-in-the-release-key) does that. There is no
transparency log.

**Pending, not active:** the release key and signing in the release workflow,
backed by **Azure Key Vault** and following the approach the Pretorin CLI
already uses for its own releases
([#80](https://github.com/pretorin-ai/compliance-claw/issues/80)). That is
production / internal-pilot work; see the hardening ledger in
[SECURITY.md](../SECURITY.md). Until it lands, the digest pin is the control.


## Building locally instead (development)

Contributor builds use a separate local image. See
[development setup and build commands](../CONTRIBUTING.md#how-to-build-a-candidate-image).
