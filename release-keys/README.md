# release-keys/ — the Compliance Claw release trust key

`compliance-claw-release.pub` in this directory is the one public key that
verifies Compliance Claw release sets: the record signature
(`compliance-claw-release.json.sig`) and the image signature at the recorded
digest. [`scripts/release-assets.py`](../scripts/release-assets.py) reads it
from this path in its own checkout, and from no other place.

**The key is not committed yet.** Until it is, `finalize` and `publish` in the
release workflow refuse, and customer install and update refuse every release.
There is no placeholder key and no unsigned fallback.

It is separate from [`vendor/cosign.pub`](../vendor/README.md), which is the
Pretorin CLI key. One key does not verify the other's artifacts.

## Format

| | |
| --- | --- |
| Type | ECDSA P-256 (`prime256v1`) public key |
| Encoding | One PEM `PUBLIC KEY` (SubjectPublicKeyInfo) block, uncompressed point |
| Fingerprint | Lowercase hex SHA-256 of the DER SubjectPublicKeyInfo |

Compute the fingerprint:

```sh
openssl pkey -pubin -in release-keys/compliance-claw-release.pub -outform DER | sha256sum
```

The final release record names this fingerprint in `signature.key_sha256`.
`release-assets.py check` refuses a record that names another key.

## Adding or changing the key

The private key never leaves the protected signer. A maintainer adds the
public key in a reviewed PR:

1. Export the public key from the signer and compute its fingerprint as above.
2. A second maintainer computes the fingerprint of the committed file and
   compares it with the signer's fingerprint through a separate channel.
3. Record the fingerprint and the date here. The release workflow and this
   directory need code-owner review (`.github/CODEOWNERS`).

A changed key does not verify releases signed with the earlier key.
Deployments on an earlier checkout keep their earlier key until they update.

## First trust on a deployment

A customer checkout gets this key from the repository, never from a release
download. Before the first verified install or update, compute the fingerprint
of the checkout's key and compare it with the fingerprint that Pretorin gives
you through a channel separate from this repository. Stop if they differ. See
[checking a release set](../docs/image-verification.md#checking-a-release-set).
