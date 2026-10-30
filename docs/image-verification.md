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
[release-set procedure](releasing.md#the-release-set) carry three assets:
`compliance-claw-release.json` (the release record), `compose.release.yaml` (an
overlay that selects the release digest for `openclaw` and `cli`), and
`sbom-X.Y.Z.spdx.json`. Earlier releases have only the SBOM. A draft release is
a candidate, not a customer release.

The source tag `vX.Y.Z` can still pin the previous image in `compose.yaml`. That
pin moves only in the commit after the release. The release overlay is what
selects the release image for the tagged source.

Check a downloaded set from a checkout of the release tag:

```sh
gh release download vX.Y.Z --repo pretorin-ai/compliance-claw --dir /tmp/cc-vX.Y.Z
python3 scripts/release-assets.py check --dir /tmp/cc-vX.Y.Z --version X.Y.Z --source .
```

The check refuses a candidate record, a changed or extended overlay, an asset
whose SHA-256 or size differs from the record, and a checkout whose tag or
`HEAD` is not the recorded commit. It reports `unsigned`: the record is not
signed yet.

The verified record and overlay belong in the repository root, where both names
are gitignored. Select the overlay directly after `compose.yaml`, so that secret,
effort, customer, and restore overlays keep their order and precedence:

```dotenv
COMPOSE_FILE=compose.yaml:compose.release.yaml:compose.secrets.yaml:compose.efforts.yaml
```

Then confirm what Compose will run (no daemon is needed):

```sh
python3 scripts/release-assets.py check --compose
```

| Exit | Meaning |
| --- | --- |
| 0 | The set is valid and, with `--compose`, selected for both services. |
| 1 | The record, overlay, an asset, a checksum, the stage, or the version is invalid or does not match. |
| 3 | The checkout is not at the recorded commit, or the tag names another commit. |
| 4 | Compose selects another image: the overlay is not selected, or a later overlay sets `image`. The check reports it and changes nothing. |
| 5 | Git or Docker Compose cannot run, or the selection does not render. |

`scripts/update.sh` in this version does not download, check, or replace a
release set. While `compose.release.yaml` is selected, it keeps selecting its own
release. `scripts/bootstrap.sh` and `scripts/smoke.sh` report the selected image,
not the base pin.

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
| **Vulnerability scan** at release | fixable HIGH and CRITICAL findings block publication |
| **Release record** with asset checksums | the source commit, version, digest, overlay, and SBOM belong together |
| Documented release provenance | the workflow, the digest, and the version pin are all recorded |

The SBOM is not attached to the OCI image and is not signed. It is available
as a workflow artifact and as an asset on the GitHub Release. See the
[release procedure](releasing.md).

The release record is not signed. Anyone who can publish a release can publish
a record that agrees with itself. The record binds the files together; it is no
proof of who made them.

**Planned, not implemented:** image and record signing backed by **Azure Key
Vault**, following the approach the Pretorin CLI already uses for its own
releases. The record reserves `compliance-claw-release.json.sig` for it. That is
production / internal-pilot work; see the hardening ledger in
[SECURITY.md](../SECURITY.md). Until it lands, the digest pin is the control.

## Building locally instead (development)

Contributor builds use a separate local image. See
[development setup and build commands](../CONTRIBUTING.md#how-to-build-a-candidate-image).
