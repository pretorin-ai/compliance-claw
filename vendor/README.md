# vendor/ — committed trust anchors

## `cosign.pub`

The Pretorin CLI release signing key. This is the **root of the entire supply-chain
trust chain** in this repo: `scripts/verify-pretorin.sh` uses it to verify the cosign
signature over `SHA256SUMS`, and only then are the checksums in that manifest trusted
enough to gate the binary.

| | |
| --- | --- |
| SHA256 | `76ebd1120eaf795fffa6a3a92754cbfbaeb06afd1faef5b23f54eb4dfb7bc53b` |
| Size | 178 bytes |
| Type | ECDSA P-256 (`prime256v1`) public key, SPKI PEM |
| Added | 2026-08-03, for Pretorin CLI 0.26.14 |

### Why it is committed rather than downloaded

Fetching the key at build time would make the trust anchor "whatever the server
served" — an attacker who can serve a substituted key can serve a matching signature,
and the verification becomes theatre. Committing it means the anchor is reviewed once,
in a diff, and any change to it is visible in `git log`.

### Provenance

Published as a release asset by **two independent repositories**, byte-identical in both
(verified 2026-08-03):

- `https://github.com/pretorin-ai/homebrew-tap/releases/download/v0.26.14/cosign.pub` (public;
  the source this repo's build uses)
- `https://github.com/pretorin-ai/pretorin-cli/releases/download/v0.26.14/cosign.pub` (private;
  the build origin)

It is also **byte-identical across releases v0.26.10 → v0.26.14**, which is what
establishes it as a stable release key rather than a per-release key.

### Re-verifying this anchor

Confirm the committed bytes still match what upstream publishes:

```sh
curl -fsSL https://github.com/pretorin-ai/homebrew-tap/releases/download/v0.26.14/cosign.pub \
  | shasum -a 256
# expect 76ebd1120eaf795fffa6a3a92754cbfbaeb06afd1faef5b23f54eb4dfb7bc53b
```

Confirm the key actually validates a release manifest, without involving cosign at all —
useful as an independent second opinion:

```sh
curl -fsSL -O https://github.com/pretorin-ai/homebrew-tap/releases/download/v0.26.14/SHA256SUMS
curl -fsSL https://github.com/pretorin-ai/homebrew-tap/releases/download/v0.26.14/SHA256SUMS.sig \
  | base64 -d > SHA256SUMS.sig.der
openssl dgst -sha256 -verify cosign.pub -signature SHA256SUMS.sig.der SHA256SUMS
# expect: Verified OK
```

### When to update

Only if Pretorin rotates its signing key. Treat that as a security-relevant change: verify
the new key against both repositories above, confirm the SHA256 in this file, and call it
out explicitly in the commit message.
