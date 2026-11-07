# Publishing GameShelf updates

GameShelf uses [Sparkle](https://sparkle-project.org/documentation/publishing/)
for application updates. This sidecar publishes update metadata for an already
built and uploaded GitHub release; it does not build the app or access game
libraries, NAS shares, saves, or other user data.

The public configuration is `Resources/Updates.json`:

- `feedURL`: `https://github.com/Je1ghtxyuN/gameshelf-for-mac/releases/latest/download/appcast.xml`
- `publicKey`: the base64 Ed25519 public key used by the shipped app.

The bundle must contain the same configuration and set `SUFeedURL`,
`SUPublicEDKey`, `SURequireSignedFeed=true`, and
`SUVerifyUpdateBeforeExtraction=true`. Keep increasing `CFBundleVersion`
(the Sparkle build number) even when the marketing version changes.

## One release workflow

1. Build and verify the release app using the normal build/package process.
2. Create a draft release in `Je1ghtxyuN/gameshelf-for-mac` with a numeric
   version tag such as `v1.2.5`. Attach exactly one completed DMG named
   `GameShelf-v1.2.5-macOS-arm64.dmg`. Finish uploading all assets before publishing.
3. Publish as a stable release and make it GitHub's latest release.
   `.github/workflows/updates.yml` runs automatically on `release: published`.
4. Confirm that the workflow succeeds and the release contains `appcast.xml`.
   Clients use GitHub's latest-release download URL above.

The workflow checks out trusted `main`, never code from the release tag. It uses
only `contents: write`, serializes stable-feed publications, and does not persist
checkout credentials. Release tags enter the shell through an environment
variable. Keep `main` and workflow changes protected by review.

Configure the repository Actions secret **`SPARKLE_PRIVATE_KEY`** separately.
Its value must be the base64 encoding of the **32-byte Ed25519 private seed**,
matching the configured public key. This is Sparkle 2.10.1's current exported
key format and is compatible with CryptoKit's
`Curve25519.Signing.PrivateKey.rawRepresentation`. Older 96-byte hashed-key
exports are deliberately rejected. The publishing script does not generate,
import, export, or modify production keys and never uses Keychain.

`Tools/publish_appcast.py` validates the seed's derived public key before
signing. Private seed copies live in a temporary directory with mode 0700,
in a file created with mode 0600; the directory is removed on exit. The secret
is removed from child-process environments. Tool output is captured and never
forwarded because an upstream error can echo malformed key material. Never
use shell tracing, put a seed on a command line, or upload private files as
workflow artifacts. The script has no access to local signing files in CI.

## Verification and publication order

The publisher fetches release metadata and the attached DMG through this
repository's GitHub API. It rejects drafts, prereleases, nonnumeric tags,
releases other than GitHub's latest stable release, wrong repository/download
URLs, incomplete uploads, version/name mismatches, and multiple DMGs.
It verifies the DMG's length and GitHub SHA-256 digest when available. It mounts
the DMG read-only, checks the app's metadata, arm64 executable, update settings,
and code signature, then unmounts it. It does not execute the released app.

The official Sparkle **2.10.1** distribution is downloaded from its GitHub
release and must match SHA-256
`1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`.
A supplied cached archive receives the same check and is freshly extracted;
existing extracted tools are not trusted for publishing.

`generate_appcast --ed-key-file` creates a one-item feed with no deltas.
The publisher validates the feed's build and marketing versions, minimum OS,
arm64 hardware restriction, exact download URL, size, and Ed25519 DMG signature
against the configured public key. It then explicitly signs `appcast.xml` using
`sign_update --ed-key-file`, verifies that signed feed using the official tool,
and performs read-only XML validation. **No XML serialization or other
modification is allowed after signing.** Release metadata is checked again
immediately before upload. The validated, signed feed is the last release asset
uploaded. An existing `appcast.xml` is never deleted or overwritten.

## Local preview and publishing

Requires macOS, Python 3.12 or later, GitHub CLI authenticated for this repository,
and the pinned Python signature-verification dependency:

```sh
python3 -m venv /tmp/gameshelf-publish-venv
/tmp/gameshelf-publish-venv/bin/python -m pip install cryptography==46.0.3
/tmp/gameshelf-publish-venv/bin/python -m unittest discover -s Tests -p test_update_release.py -v
```

Use an existing private seed file protected with mode 0600; do not paste its
contents into a command. From the repository root, generate a local preview
without modifying GitHub:

```sh
/tmp/gameshelf-publish-venv/bin/python Tools/publish_appcast.py \
  --tag v1.2.5 \
  --key-file validation/update-signing/private-key.txt \
  --sparkle-archive build/sparkle/Sparkle-2.10.1.tar.xz \
  --output /tmp/gameshelf-appcast.xml
```

Add `--publish` to upload instead of writing the preview. Omitting
`--sparkle-archive` downloads the pinned distribution. Omitting `--key-file`
reads `SPARKLE_PRIVATE_KEY` from the environment. Both local and CI publishing
use the same validation and signing path.

For a failed run after fixing missing/incomplete assets, rerun **Publish Sparkle
update feed** through Actions `workflow_dispatch`, supplying the release tag
and using the workflow on `main`. If a live feed already exists, the publisher
fails closed; make a new release rather than replacing signed metadata in place.

## Current limits

Only a single arm64 DMG is supported. Intel, universal binaries, and separate
architecture DMGs fail closed until an architecture-aware publication policy is
implemented. The feed contains only the latest release: no history, deltas, or
separate prerelease channels. No changes are made to updater implementation.
Signature checking here does not replace Developer ID signing/notarization or
manual installation/update acceptance tests.

GitHub moves `/releases/latest` when a release becomes latest, before this
workflow finishes. During publishing or after a failed run, the feed URL may
return 404 until a successful upload; clients must retain their installed app.
GitHub does not provide an atomic transaction combining release publication
and asset upload. Do not publish a new stable release before its DMG is ready.
Concurrent changes outside this serialized workflow can still race GitHub's
latest pointer; the publisher checks it twice and refuses known stale releases.

Tests use public fixture seeds only. Policy, bad downloads, version mismatches,
key mismatches, bundle settings, enclosure signatures, and signed-feed tampering
are covered. The official-tool signing smoke test runs when the extracted
Sparkle distribution is present on macOS; otherwise it is explicitly skipped.
