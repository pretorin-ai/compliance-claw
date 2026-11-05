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

**Releases v0.5.3 and earlier are unsigned.** Nothing proves who published
them, so `check` refuses them with exit 6, and guided install and update refuse
them. **No signed release exists yet:** the release key is not committed (see
[release-keys/](../release-keys/README.md)). Do not install a release set by
hand to work around this.

### What `check` verifies for a signed release

For a set whose record says `signature.status: signed`, `check` passes only when
all of these are true:

1. The record is final, canonical and valid, and every asset matches its
   recorded SHA-256 and size. The record binds the overlay and the SBOM, so a
   changed SBOM or overlay fails.
2. `signature.key_sha256` in the record is the fingerprint of
   `release-keys/compliance-claw-release.pub` **in your checkout**.
3. `compliance-claw-release.json.sig` verifies over the exact record bytes with
   that key (openssl).
4. The image signature at the recorded digest verifies with the same key
   (`cosign verify --key … --insecure-ignore-tlog=true`), and every verified
   payload names exactly the recorded digest and image repository.
5. With `--source`, the checkout is at the recorded tag and commit.

A `signed` status alone proves nothing. A missing, altered, stale, or wrong-key
record signature, a missing image signature, or an image signature for another
digest exits 6. The key is never taken from a download or an option.

The image check needs:

- a Linux amd64 host (the deployment VM). Other hosts get exit 5;
- the cosign that [versions.env](../versions.env) pins. `check` downloads that
  exact file to a temporary file, compares it with `COSIGN_SHA256`, and keeps it
  in `.cache/release-tools/` (gitignored). It compares the cached file with the
  pin again on every use. A failed download or checksum exits 5;
- this host's registry login. The package is not public, so run
  `docker login ghcr.io` first (a classic token needs `read:packages`). cosign
  uses that login; `check` handles no credential. Without it, exit 5.

`--record-only` checks everything except the image signature, and says
`image signature NOT checked here`. The install and update tools use it only
for later checks of a set that they already verified in full.

### First trust in the release key

The release key in your checkout is the root of this trust. A changed key in a
compromised checkout would make a forged release verify. Before the first
signed install or update, compare the key fingerprint with the one Pretorin
gives you through a channel separate from this repository:

```sh
openssl pkey -pubin -in release-keys/compliance-claw-release.pub -outform DER | sha256sum
```

Stop if the fingerprints differ. After that, an update checks a new release
with the key of the checkout you already trust, never with the key in the new
tag. A key change in a later release is visible in its diff of
`release-keys/`.

### Inspect a published set

To inspect a published set without installing it, download it (no credential
is needed; the directory must be empty or absent) and check it against a
checkout of the release tag:

```sh
python3 scripts/release-assets.py fetch --version X.Y.Z --dir /tmp/cc-vX.Y.Z --json --image-access
python3 scripts/release-assets.py check --dir /tmp/cc-vX.Y.Z --version X.Y.Z --source .
```

`fetch` downloads the record, the overlay, the SBOM and, for a signed record,
the record signature. It checks the download integrity only and reports the
signature status. With `--image-access` it also asks the registry, without a
credential, and reports `image_access`: whether the registry serves the digest
without a login (`anonymous`), refuses it (`login-required`), or cannot tell
(`unknown: …`). Today it reports `login-required`. Install and update do not
make this call.

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

Then confirm what Compose will run (no daemon is needed):

```sh
python3 scripts/release-assets.py check --record-only --compose
```

The check keeps the rendered Compose model in memory and prints only image
references. A legacy `.env` selection renders secret values into that model, so
do not save it to a file. A caller that already renders it can pipe it:
`docker compose --profile cli config --format json | python3 scripts/release-assets.py check --record-only --rendered -`.

| Exit | Meaning |
| --- | --- |
| 0 | The set is valid, both signatures verify (or `--record-only`: the record signature), and with `--compose` it is selected for both services. |
| 1 | The record, overlay, an asset, a checksum, the stage, or the version is invalid or does not match. |
| 3 | The checkout is not at the recorded commit, or the tag names another commit. |
| 4 | Compose selects another image: the overlay is not selected, or a later overlay (for example a restore overlay) sets `image`. The check prints the expected and effective references and changes nothing. |
| 5 | Git, Docker Compose, openssl, the download, or the image check cannot run: not Linux amd64, cosign download or checksum, or no registry access. |
| 6 | The release is not signed, or a signature does not verify with the key in this checkout. Customer install and apply refuse it. |

Exit 2 is a usage error.

`scripts/update.sh --release vX.Y.Z --preview` downloads and checks a release
set without a change; apply installs it after the checks in
[Routine deployment update](upgrade.md#routine-deployment-update). Apply
refuses an unsigned release set. While `compose.release.yaml` is selected, it
keeps selecting its own release. `scripts/bootstrap.sh` and `scripts/smoke.sh`
report the selected image, not the base pin.

## What this does and does not prove

> **Signatures prove the key, not the content.** A verified signature proves
> that the holder of the release key signed this record and this digest. The
> record binds the source commit, the overlay and the SBOM hash. It does not
> prove that the key in your checkout is the right key; the
> [first-trust comparison](#first-trust-in-the-release-key) does that. There is
> no transparency log. Unsigned releases (v0.5.3 and earlier) give integrity
> only: a digest is these exact bytes, not proof of who built them.

The image's integrity and authenticity controls:

| Control | What it gives you |
| --- | --- |
| GHCR image pinned by **immutable digest** | the bytes are the bytes that were built and scanned |
| **SBOM** generated per release (SPDX JSON) | a package inventory, retained as a workflow artifact and a release asset; its hash is in the signed record |
| **Vulnerability scan** at release | fixable HIGH and CRITICAL findings block publication, except the findings inherited from the official upstream image that [.trivyignore.yaml](../.trivyignore.yaml) lists; those stay in the report |
| **Release record** with asset checksums | the source commit, version, digest, overlay, and SBOM belong together |
| **Record and image signatures** (signed releases only) | the release key signed exactly this record and this digest |
| Documented release provenance | the workflow, the digest, and the version pin are all recorded |

The SBOM is not attached to the OCI image and has no signature of its own. The
signed record covers its hash and size.


## Building locally instead (development)

Contributor builds use a separate local image. See
[development setup and build commands](../CONTRIBUTING.md#how-to-build-a-candidate-image).
