# Release hygiene addendum — provenance, staging refs, and the update path

Follow-up to the **v0.2.0 retro**, not a new phase. Three defects surfaced when the
release pipeline ran for real for the first time; this records what each one was
and what was done about it. No version bump: these changes prove themselves at the
next regular release.

## 1. The image did not know what version it was

The published `v0.2.0` image self-reports `IMAGE_VERSION=0.1.0` in
`/opt/compliance-claw/versions.env`.

Not a runtime bug — nothing reads that copy at run time. The Dockerfile sources it
once at build time for `MODEL` and `CONFIG_TEMPLATE_VERSION`, and that is the only
consumer. It is a **provenance** bug: an operator asking the image what it is gets a
stale answer, which is the same species as the false "signed attestation" comment
that justified v0.1.1.

The cause is ordering, not carelessness. `versions.env`'s `IMAGE_VERSION` describes
*what a checkout deploys*, and the commit that moves it lands **after** the release
is published — so at build time it necessarily still names the previous release.

**Fix.** The version comes from the git tag, which is already the single source of
truth at release time, and is passed into the build as `IMAGE_SELF_VERSION`:

- `LABEL org.opencontainers.image.version` — an `ARG` rather than a value computed
  in a `RUN`, because a `LABEL` can only reference a build argument.
- the `IMAGE_VERSION=` line of the image's own copy of `versions.env`, rewritten
  after the file is sourced, so `MODEL` and `CONFIG_TEMPLATE_VERSION` are unaffected.

The release step asserts both before the image reaches a scan, a push or an
operator. The repo's `versions.env` is untouched and still guards compose agreement
(`smoke.sh` A4b).

The default is deliberately **not** a release number. A build with no argument says
`0.0.0-dev`; `bootstrap.sh --build` sharpens that to `0.0.0-dev+<shortsha>`. A local
build must never be able to impersonate a release.

| Build path | Self-reported version |
| --- | --- |
| `release.yml` | the git tag's version |
| `bootstrap.sh --build` | `0.0.0-dev+<shortsha>` |
| bare `docker build .` | `0.0.0-dev` |

## 2. Staging refs accumulated, and could not be deleted

The workflow pushed to `${IMAGE_REPO}:build-${GITHUB_SHA}`, called it throwaway, and
never removed it. Three leftovers existed.

**The finding that shaped the fix: GHCR cannot delete a tag without deleting the
image.** A GHCR *package version* is a digest; tags are attributes of it. The live
listing shows one version carrying two tags:

```
build-c8189ea82b0fa6a1e80d228250f9fbb5d825e04b,0.2.0   sha256:e123bf533b74
<untagged>                                             sha256:351ecb370d07
build-fd9252596ed7339ced9a32e5acfa533c5e359662         sha256:346192592290
0.1.0                                                  sha256:58690e31c6d3
```

The only delete GitHub exposes is `DELETE /…/versions/{id}`, which removes the
**digest**. So a cleanup step that deleted the staging tag's version after a
successful release would have **deleted the image it had just released** —
`build-c8189ea…` and `0.2.0` are the same version. Registry
`DELETE /v2/<name>/manifests/<tag>` is not a safe substitute: implementations differ
on whether it drops the tag or the manifest, and guessing wrong destroys a release.

**Fix — prevention rather than deletion.**

- The staging ref is now the constant `${IMAGE_REPO}:build`. `docker push` requires
  a tag, so *some* tag must exist before a digest can be published; a constant name
  means at most one ever exists and nothing accumulates. Nothing is deleted on the
  success path.
- A best-effort step reclaims a digest that was pushed but **never tagged** — a run
  that died between push and tagging. The guard is the tag set: it deletes only when
  the version's tags are exactly `build`, which is impossible once a release tag has
  been applied. That interlock is the safety property, not a nicety.
- `concurrency` was widened from per-`ref` to repo-wide, so two releases cannot
  overlap on the shared staging ref. Harmless if they did — the digest is read from
  the local image right after push, never by resolving the tag — but a publish
  pipeline that interleaves with itself is a bad thing to have to reason about.

The three digest-verification gates in the tagging step are unchanged, byte for
byte.

**Residue, stated plainly:** `build-c8189ea…` is welded to the `v0.2.0` digest and
cannot be removed without deleting `v0.2.0`. It stays, as an artifact of the old
design. The two genuinely orphaned versions (`sha256:346192…`, the abandoned first
attempt, and untagged `sha256:351ecb…`) are safe to delete by hand.

## 3. No update path, and no way to know you needed one

An operator on an existing deployment had no single command, and nothing told them
they were behind the pin.

**`scripts/update.sh`** — fast-forward, pull the pinned image, restart, then report.
It refuses rather than guesses (dirty tree, detached HEAD, no upstream, diverged
branch, build overlay selected), naming the exact command each time, in the same
style as `bootstrap.sh`. It never runs `down -v`, never edits a config, never
touches `.env` or the target clones.

Config drift is surfaced by **re-running the entrypoint** through the one-shot `cli`
service and reporting its existing warning, rather than reimplementing the
comparison — one source of truth, and it cannot drift from the entrypoint's own.

**`smoke.sh`** gained a local, offline comparison of the running container's digest
against the digest `compose.yaml` pins. It emits `NOTE`, never `FAIL`: being
mid-update is not being broken, and CI runs the suite with no deployment at all.

## Verification

- Build with `--build-arg IMAGE_SELF_VERSION=9.9.9-test` → OCI label and baked
  `versions.env` both report `9.9.9-test`. Build with no argument → both report
  `0.0.0-dev`. The repo's `versions.env` stays at the release it pins.
- The three tagging gates are byte-identical to `master` (checked by parsing both
  files, not by eye). A dry run *skips* push and tag, so the gates themselves are
  re-proven only by the next real release — their behaviour is already evidenced by
  the v0.2.0 run that caught `imagetools create` publishing a rewrapped manifest.
- `update.sh` against a throwaway clone reset to the pre-pin commit: pulls,
  restarts, lands on v0.2.0; drift warning and remedies appear when the volume's
  template marker is behind; second run is a clean no-op; refusals fire.
- The digest notice fires when running ≠ pinned and is silent when they agree.
- `smoke.sh --no-creds` green, and CI green on the PR.
