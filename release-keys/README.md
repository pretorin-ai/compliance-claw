# release-keys/ — the Compliance Claw release trust key

`compliance-claw-release.pub` in this directory is the one public key that
verifies Compliance Claw release sets: the record signature
(`compliance-claw-release.json.sig`) and the image signature at the recorded
digest. [`scripts/release-assets.py`](../scripts/release-assets.py) reads it
from this path in its own checkout, and from no other place.

**The key is not committed yet.** There is no placeholder key and no unsigned
fallback. Every published release is unsigned, and customer install and update
refuse it. The release workflow still finalizes unsigned records, as before.
Key integration and signing activation are pending
([#80](https://github.com/pretorin-ai/compliance-claw/issues/80)).

It is separate from [`vendor/cosign.pub`](../vendor/README.md), which is the
Pretorin CLI key. One key does not verify the other's artifacts.

## Format

| | |
| --- | --- |
| Type | ECDSA P-256 (`prime256v1`) public key |
| Encoding | One PEM `PUBLIC KEY` (SubjectPublicKeyInfo) block |
| Fingerprint | Lowercase hex SHA-256 of the DER SubjectPublicKeyInfo |

`release-assets.py` checks the key with OpenSSL 1.1.1 or later: exactly one PEM
block, a valid public point (`openssl pkey -pubcheck`), and the `prime256v1`
curve. Compute the fingerprint. The command prints it only when OpenSSL accepts
the key:

```sh
openssl pkey -pubin -in release-keys/compliance-claw-release.pub -pubcheck \
  -outform DER -out /tmp/cc-release-key.der && sha256sum /tmp/cc-release-key.der
```

A signed release record names this fingerprint in `signature.key_sha256`.
`release-assets.py check` refuses a record that names another key.

## Changes to this directory

The private key is not stored in this repository. A change here needs
code-owner review (`.github/CODEOWNERS`). A changed key does not verify
releases signed with the earlier key, and `scripts/update.sh` in a checkout with
the earlier key refuses a release signed with the new key (exit 6).

## First trust on a deployment

A customer checkout gets this key from the repository, never from a release
download. Before the first verified install or update, compute the fingerprint
of the checkout's key and compare it with the fingerprint that Pretorin gives
you through a channel separate from this repository. Stop if the command fails
or the fingerprints differ. See
[first trust in the release key](../docs/image-verification.md#first-trust-in-the-release-key).
