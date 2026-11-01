---
name: build-release
description: "Build a signed arm64 release APK of this pinned Hermes Android fork from the security-reviewed tag. Use when the user wants to build or release the Hermes APK; putting it on a phone is /tmichub:serve-apks."
disable-model-invocation: true
---

# Build the Hermes release APK

## User Input

```text
$ARGUMENTS
```

## Goal

Build the release APK from the security-reviewed tag, signed with this fork's pinned release key, then hand it to
`/tmichub:serve-apks`, which publishes it and serves it to the phone.

## This fork stays pinned to the reviewed tag

`tristaoeast/hermes-android` is a personal fork of `rusty4444/hermes-android`,
pinned to **`v2.1.22` (`2f81f5c`)**, the release covered by the security review:
a full review of `v2.1.20` (`46bcc4b`), then a review of the
`v2.1.20..v2.1.22` diff, which passed (verdict CLEAN, 2026-10-18; report
`~/workspaces/security-reviews/hermes-android/hermes-android-v2.1.20-to-v2.1.22-diff-review.md`).
Its default branch carries no upstream commit after that tag; GitHub Actions
are disabled on the fork so upstream workflows never run there.

- The `upstream` remote exists only to diff future releases. **Never merge or
  pull from it.**
- Syncing to a newer upstream release requires a security review of
  `git diff <reviewed-tag>..<new-tag>` (e.g. `v2.1.22..v2.1.23`) **first**.
  Only after that review passes may the default branch move to the new tag.
- Build only from a clean tree at the reviewed tag. Tooling changes on this
  fork (like this skill) must not touch app code.
- Do not apply anything from `server-patches/`.

## Step 1: Build

From a clean checkout at the reviewed tag:

```bash
bash .claude/skills/build-release/scripts/build-release-arm64.sh
```

It refuses a dirty tree and a Flutter version other than the one
`.github/workflows/release.yml` pins (3.44.0 for v2.1.22), looking first in
`~/flutter-sdks/<version>/` (`FLUTTER=<path>` to override). Then it runs
`flutter pub get --enforce-lockfile` and

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --split-debug-info=build/app/outputs/symbols
```

and checks that the APK's signer is the pinned release certificate (see
Signing). Output:
`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`, versionCode
`<base>*10+2` (21652 for v2.1.22), which matches upstream's split scheme.

### Memory — never let the build thrash the host

`android/gradle.properties` asks for an 8 GiB Gradle heap. On a shared box with
no swap, a release build with that setting exhausted RAM and left the host
unreachable for about 50 minutes. The script therefore:

- refuses to start when less than 6 GiB is available (`MIN_AVAILABLE_GIB`)
- replaces the Gradle settings for the build only with
  `org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g -XX:ReservedCodeCacheSize=256m`,
  `org.gradle.workers.max=2`, `org.gradle.daemon=false` and
  `kotlin.compiler.execution.strategy=in-process`, then restores the file with
  `git checkout -- android/gradle.properties` (these settings do not change the APK)
- runs `flutter pub get` and `flutter build` inside
  `systemd-run --user --scope -p MemoryMax=5G -p MemorySwapMax=0`, so the kernel
  OOM-kills the build instead of the host thrashing (`BUILD_MEMORY_MAX`)
- runs `./gradlew --stop` afterwards so no daemon keeps holding RAM

If the build gets OOM-killed, do not raise the cap to push it through on a
shared machine; free memory or build elsewhere.

### Signing — never change the key

Android keys an install by package + signing certificate, so a new key forces
an uninstall, which wipes the app's data. The release build is signed with this
fork's **dedicated release key**, stored in Bitwarden Secrets Manager (project
`agentic-ai`, `5d4146c9-5192-424f-a16f-b4d200be3248`):

| Secret | ID |
|---|---|
| `HERMES_ANDROID_RELEASE_KEYSTORE_B64` (PKCS12 keystore, base64) | `f177114d-668b-4ad8-a575-b4e70163b506` |
| `HERMES_ANDROID_RELEASE_STORE_PASSWORD` | `5cb3dafd-8c01-4e69-9fb5-b4e70163b550` |
| `HERMES_ANDROID_RELEASE_KEY_PASSWORD` | `21ce8d1f-90e2-4271-81c3-b4e70163b58f` |
| `HERMES_ANDROID_RELEASE_KEY_ALIAS` | `bf755219-9639-4f6c-b4ef-b4e70163b5cd` |

Its certificate SHA-256 is pinned in the script:
`2a29e042468c29c250aef6bafb7cea5725c3658d7558d13d0964b47d5b7259cf`.

- The script needs `bws`, `jq` and `BWS_ACCESS_TOKEN` (from `~/.bashrc`) and
  fails if any is missing. It never falls back to another key.
- It fetches all four secrets with **one** `bws secret list` call (bws
  rate-limits hard: HTTP 429 after a handful of calls; do not loop `bws secret
  get`). The output goes to a private temp dir under `$XDG_RUNTIME_DIR` (umask
  077), where the keystore is decoded, and is shredded right after.
- Before building it checks that the keystore's certificate is the pinned one,
  so a wrong key fails in seconds, not after the build. After the build it
  checks that the APK's only signer is that certificate.
- `android/app/build.gradle.kts` signs a release only when `<repo>/key.properties`
  exists. The script writes it (mode 600, gitignored; it checks that) pointing
  at the temp keystore, and shreds it and the temp dir on exit, on success,
  failure or Ctrl+C. Never commit it, and never print it or the bws output.
- Passwords never go on a command line: keytool reads the store password with
  `-storepass:env`, and key.properties is written from environment variables.
- `--check-signing` runs only the fetch and the certificate check, then stops
  (one bws call, no build).
- Overrides: `HERMES_BWS_PROJECT_ID`, `HERMES_BWS_KEYSTORE_ID`,
  `HERMES_BWS_STORE_PASSWORD_ID`, `HERMES_BWS_KEY_PASSWORD_ID`,
  `HERMES_BWS_KEY_ALIAS_ID`. Or `HERMES_SIGNING_DIR=<dir>` reads the key from a
  local directory instead of Bitwarden: mode 700, outside any git work tree,
  holding mode-600 files `keystore.p12`, `store_password`, `key_password` and
  `key_alias`.
- **Never create a new keystore.** If the secrets are lost or the script reports
  a certificate other than the pinned one, stop and restore the keystore from
  Bitwarden (or its backup). A new key cannot update installs signed with this
  one.
- Upstream's comment in `build.gradle.kts` says never fall back to the debug
  key. The script never does. `~/.android/debug.keystore` is
  gallery-dl-mobile's signing key; this fork does not use or touch it.

**Builds up to the first v2.1.20 APK were signed with that debug keystore.**
The release key's signature differs, so installing a release-key build over
that app fails with a signature mismatch: uninstall it first (export
connections first if needed, since the uninstall wipes its data). Later
release-key builds update in place.

## Step 2: Serve

Run `/tmichub:serve-apks` from this checkout. It publishes
`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` into the shared directory as
`hermes-android-<versionName>-<versionCode>-arm64-v8a-release-<build time>.apk` and serves it on port 9120 beside
every other app's builds.

The build script's last line still says to serve with the old `start.sh`. That script is gone; the build
script is kept byte-for-byte as reviewed. Use `/tmichub:serve-apks` instead.

## Operating Principles

- This skill builds; it never starts a server. Serving is `/tmichub:serve-apks`.
- **Installing over an upstream-signed install fails** with a signature
  mismatch (upstream releases are signed with the maintainer's key). Uninstall
  the upstream app first. That wipes its data, so export connections first if
  needed. The same applies to switching to or from any other signer, such as
  an F-Droid build. A debug build (`.dev` suffix) is a separate package and
  installs alongside
