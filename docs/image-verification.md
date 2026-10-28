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
| Documented release provenance | the workflow, the digest, and the version pin are all recorded |

The SBOM is not attached to the OCI image and is not signed. It is available
as a workflow artifact and as an asset on the published GitHub Release. See the
[release procedure](releasing.md).

**Planned, not implemented:** image signing backed by **Azure Key Vault**,
following the approach the Pretorin CLI already uses for its own releases. That is
production / internal-pilot work; see the hardening ledger in
[SECURITY.md](../SECURITY.md). Until it lands, the digest pin is the control.

## Building locally instead (development)

Contributor builds use a separate local image. See
[development setup and build commands](../CONTRIBUTING.md#how-to-build-a-candidate-image).
