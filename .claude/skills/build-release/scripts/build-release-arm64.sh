#!/usr/bin/env bash
set -euo pipefail

# Build a signed arm64-v8a release APK of the checkout you run it from.
#
# Signing uses this fork's dedicated release key (see SKILL.md), kept in
# Bitwarden Secrets Manager. For each build the script fetches the keystore and
# its credentials with ONE `bws secret list` call (bws rate-limits hard) into a
# private temp dir, checks the keystore's certificate against the pinned
# fingerprint, and writes <repo>/key.properties (mode 600), the file
# android/app/build.gradle.kts signs a release from. On exit, success or
# failure, it shreds key.properties and the temp dir. Secrets never reach argv,
# stdout or git: keytool reads the password from the environment, and
# key.properties is gitignored. The script never generates a key and never
# falls back to the debug keystore. After the build it checks that the APK's
# signer is the pinned certificate.
#
# Memory: android/gradle.properties asks for an 8 GiB Gradle heap, which on a
# shared box with no swap thrashed the whole host until it was unreachable.
# So the build refuses to start below MIN_AVAILABLE_GIB of available RAM,
# swaps in small Gradle settings for the build only (restored on exit; they do
# not change the APK), and runs inside a memory-capped cgroup so the kernel
# OOM-kills the build instead of the host thrashing. If the build is killed,
# do not raise the cap blindly; free memory or build on a bigger machine.
#
# Usage: build-release-arm64.sh                   (run from the checkout to build)
#        build-release-arm64.sh --check-signing   fetch and check the key, then stop
# Env:   FLUTTER       flutter binary (default: ~/flutter-sdks/<pinned>/bin/flutter,
#                      else `flutter` on PATH); must match the CI-pinned version
#        BWS_ACCESS_TOKEN  bws machine-account token (required unless HERMES_SIGNING_DIR)
#        BWS           bws binary (default: `bws` on PATH, ~/.local/bin/bws, ~/bin/bws)
#        HERMES_BWS_PROJECT_ID, HERMES_BWS_KEYSTORE_ID, HERMES_BWS_STORE_PASSWORD_ID,
#        HERMES_BWS_KEY_PASSWORD_ID, HERMES_BWS_KEY_ALIAS_ID
#                      override the Bitwarden project / secret IDs below
#        HERMES_SIGNING_DIR  read the key from this local dir instead of Bitwarden:
#                      mode 700, outside any git work tree, holding mode-600 files
#                      keystore.p12, store_password, key_password, key_alias
#        ANDROID_HOME  Android SDK (default ~/Android/Sdk)
#        BUILD_MEMORY_MAX   cgroup memory cap for the build (default 5G)
#        MIN_AVAILABLE_GIB  refuse to build below this much available RAM (default 6)

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# The release key's certificate. Public; a different signer means the wrong
# key, and installing it over the existing app would fail.
PINNED_CERT="2a29e042468c29c250aef6bafb7cea5725c3658d7558d13d0964b47d5b7259cf"
# Bitwarden Secrets Manager, project "agentic-ai". IDs are not secret.
BWS_PROJECT_ID="${HERMES_BWS_PROJECT_ID:-5d4146c9-5192-424f-a16f-b4d200be3248}"
BWS_KEYSTORE_ID="${HERMES_BWS_KEYSTORE_ID:-f177114d-668b-4ad8-a575-b4e70163b506}"             # HERMES_ANDROID_RELEASE_KEYSTORE_B64
BWS_STORE_PASSWORD_ID="${HERMES_BWS_STORE_PASSWORD_ID:-5cb3dafd-8c01-4e69-9fb5-b4e70163b550}" # HERMES_ANDROID_RELEASE_STORE_PASSWORD
BWS_KEY_PASSWORD_ID="${HERMES_BWS_KEY_PASSWORD_ID:-21ce8d1f-90e2-4271-81c3-b4e70163b58f}"     # HERMES_ANDROID_RELEASE_KEY_PASSWORD
BWS_KEY_ALIAS_ID="${HERMES_BWS_KEY_ALIAS_ID:-bf755219-9639-4f6c-b4ef-b4e70163b5cd}"           # HERMES_ANDROID_RELEASE_KEY_ALIAS
SIGNING_DIR="${HERMES_SIGNING_DIR:-}"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
KEY_PROPS="$ROOT/key.properties"
GRADLE_PROPS="android/gradle.properties"
MEMORY_MAX="${BUILD_MEMORY_MAX:-5G}"
MIN_AVAIL_GIB="${MIN_AVAILABLE_GIB:-6}"
APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"

die() { echo "ERROR: $*" >&2; exit 1; }

CHECK_ONLY=""
case "${1:-}" in
  "") ;;
  --check-signing) CHECK_ONLY=1 ;;
  *) die "usage: $0 [--check-signing]" ;;
esac

# --- Flutter: the version CI builds releases with -----------------------------
PINNED="$(sed -n "s/^ *flutter-version: *'\([^']*\)'.*/\1/p" .github/workflows/release.yml | head -1)"
[ -n "$PINNED" ] || die "no flutter-version in .github/workflows/release.yml"
if [ -z "${FLUTTER:-}" ]; then
  if [ -x "$HOME/flutter-sdks/$PINNED/bin/flutter" ]; then
    FLUTTER="$HOME/flutter-sdks/$PINNED/bin/flutter"
  else
    FLUTTER="$(command -v flutter || true)"
  fi
fi
[ -n "$FLUTTER" ] && [ -x "$FLUTTER" ] || die "flutter not found; install $PINNED into ~/flutter-sdks/$PINNED"
HAVE="$("$FLUTTER" --version --machine 2>/dev/null |
  python3 -c "import sys,json; print(json.load(sys.stdin)['frameworkVersion'])")"
[ "$HAVE" = "$PINNED" ] || die "$FLUTTER is Flutter $HAVE; release.yml pins $PINNED"

# --- Source: clean tree, report what is being built ---------------------------
[ -z "$(git status --porcelain)" ] || { git status --short; die "working tree is not clean"; }
HEAD_SHA="$(git rev-parse HEAD)"
HEAD_TAG="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
echo "Building $HEAD_SHA${HEAD_TAG:+ ($HEAD_TAG)} with Flutter $HAVE"
[ -n "$HEAD_TAG" ] || echo "WARNING: HEAD is not a tagged release"

# --- Signing prerequisites (nothing fetched yet) ------------------------------
[ ! -e "$KEY_PROPS" ] || die "$KEY_PROPS already exists; remove it first (this script shreds the file it writes)"
git check-ignore -q "$KEY_PROPS" || die "$KEY_PROPS is not gitignored; refusing to write credentials there"
if [ -n "$SIGNING_DIR" ]; then
  [ -d "$SIGNING_DIR" ] || die "HERMES_SIGNING_DIR=$SIGNING_DIR is not a directory"
  SIGNING_DIR="$(realpath "$SIGNING_DIR")"
  ! git -C "$SIGNING_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "HERMES_SIGNING_DIR=$SIGNING_DIR is inside a git work tree; keep the key outside git"
  [ "$(stat -c '%u %a' "$SIGNING_DIR")" = "$(id -u) 700" ] ||
    die "HERMES_SIGNING_DIR=$SIGNING_DIR must be yours with mode 700"
  for f in keystore.p12 store_password key_password key_alias; do
    [ -f "$SIGNING_DIR/$f" ] || die "missing $SIGNING_DIR/$f"
    case "$(stat -c '%u %a' "$SIGNING_DIR/$f")" in
      "$(id -u) 600" | "$(id -u) 400") ;;
      *) die "$SIGNING_DIR/$f must be yours with mode 600" ;;
    esac
  done
else
  BWS="${BWS:-$(command -v bws || true)}"
  for b in "$BWS" "$HOME/.local/bin/bws" "$HOME/bin/bws"; do
    if [ -n "$b" ] && [ -x "$b" ]; then BWS="$b"; break; fi
  done
  [ -n "$BWS" ] && [ -x "$BWS" ] ||
    die "bws not found (set BWS=<path> or HERMES_SIGNING_DIR). Never sign with the debug keystore instead."
  command -v jq >/dev/null || die "jq not found; it reads the bws output"
  [ -n "${BWS_ACCESS_TOKEN:-}" ] ||
    die "BWS_ACCESS_TOKEN is not set (it comes from ~/.bashrc). Never sign with the debug keystore instead."
fi

# --- Memory: enough headroom, small Gradle, capped cgroup ---------------------
if [ -z "$CHECK_ONLY" ]; then
  AVAIL_KIB="$(sed -n 's/^MemAvailable: *\([0-9]*\) kB/\1/p' /proc/meminfo)"
  [ "$AVAIL_KIB" -ge $((MIN_AVAIL_GIB * 1024 * 1024)) ] ||
    die "only $((AVAIL_KIB / 1024 / 1024)) GiB RAM available (< ${MIN_AVAIL_GIB} GiB); not building"
  command -v systemd-run >/dev/null || die "systemd-run not found; it caps the build's memory"
fi

# Everything secret lives in SECRETS_DIR, plus key.properties at the repo root
# (the path build.gradle.kts reads). Both are shredded on exit.
BUILD_UMASK="$(umask)"
umask 077
SECRETS_BASE="${XDG_RUNTIME_DIR:-$HOME/.cache}"
mkdir -p "$SECRETS_BASE"
SECRETS_DIR=""
WROTE_KEY_PROPS=""
cleanup() {
  [ -z "$WROTE_KEY_PROPS" ] || [ ! -e "$KEY_PROPS" ] || shred -u "$KEY_PROPS" || rm -f "$KEY_PROPS"
  if [ -n "$SECRETS_DIR" ] && [ -d "$SECRETS_DIR" ]; then
    find "$SECRETS_DIR" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$SECRETS_DIR"
  fi
  unset STORE_PASSWORD KEY_PASSWORD KEY_ALIAS
  [ -z "$CHECK_ONLY" ] || return 0
  git checkout -- "$GRADLE_PROPS"
  # Leave no Gradle daemon holding RAM (gradlew is generated by the build).
  [ ! -x android/gradlew ] || (cd android && ./gradlew --stop >/dev/null 2>&1) || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SECRETS_DIR="$(mktemp -d "$SECRETS_BASE/hermes-signing.XXXXXXXX")"

# --- Signing: fetch the release key, never a new one --------------------------
if [ -n "$SIGNING_DIR" ]; then
  KEYSTORE="$SIGNING_DIR/keystore.p12"
  STORE_PASSWORD="$(<"$SIGNING_DIR/store_password")"
  KEY_PASSWORD="$(<"$SIGNING_DIR/key_password")"
  KEY_ALIAS="$(<"$SIGNING_DIR/key_alias")"
  echo "Signing key: $SIGNING_DIR"
else
  KEYSTORE="$SECRETS_DIR/release.p12"
  BWS_JSON="$SECRETS_DIR/bws.json"
  # The one Bitwarden call. stdout (it holds the values) goes only to the file.
  "$BWS" secret list "$BWS_PROJECT_ID" --output json --color no > "$BWS_JSON" ||
    die "bws secret list failed (on HTTP 429, wait a few minutes; do not retry in a loop)"
  # Exactly one non-empty secret per ID; print only the secret's name.
  for id in "$BWS_KEYSTORE_ID" "$BWS_STORE_PASSWORD_ID" "$BWS_KEY_PASSWORD_ID" "$BWS_KEY_ALIAS_ID"; do
    name="$(jq -r --arg id "$id" \
      '[.[] | select(.id == $id and (.value // "") != "")] | if length == 1 then .[0].key else empty end' "$BWS_JSON")"
    [ -n "$name" ] || die "Bitwarden project $BWS_PROJECT_ID has no single non-empty secret with id $id"
    echo "Signing key: fetched $name ($id)"
  done
  secret() { jq -j --arg id "$1" '.[] | select(.id == $id) | .value' "$BWS_JSON"; }
  secret "$BWS_KEYSTORE_ID" | tr -d '[:space:]' | base64 -d > "$KEYSTORE" ||
    die "secret $BWS_KEYSTORE_ID is not valid base64"
  STORE_PASSWORD="$(secret "$BWS_STORE_PASSWORD_ID")"
  KEY_PASSWORD="$(secret "$BWS_KEY_PASSWORD_ID")"
  KEY_ALIAS="$(secret "$BWS_KEY_ALIAS_ID")"
  shred -u "$BWS_JSON"
fi
[ -s "$KEYSTORE" ] || die "keystore is empty"

# The certificate of the alias' entry, read with keytool (password from the
# environment) and matched by awk (alias from the environment), so neither
# reaches argv. Aliases compare case-insensitively, as keytool's do.
KS_CERT="$(HERMES_STORE_PASSWORD="$STORE_PASSWORD" \
  keytool -list -v -keystore "$KEYSTORE" -storetype PKCS12 -storepass:env HERMES_STORE_PASSWORD 2>/dev/null |
  KEY_ALIAS="$KEY_ALIAS" awk '
    /^Alias name: / { a = substr($0, 13); hit = (tolower(a) == tolower(ENVIRON["KEY_ALIAS"])); got = 0; next }
    hit && !got && /^[[:space:]]*SHA256: / { sub(/^[[:space:]]*SHA256: /, ""); print; got = 1 }' |
  head -1 | tr -d ':' | tr 'A-F' 'a-f')" || true
[ -n "$KS_CERT" ] || die "cannot read the key alias' certificate from the keystore (wrong store password or alias?)"
[ "$KS_CERT" = "$PINNED_CERT" ] ||
  die "keystore certificate $KS_CERT is not the pinned release certificate $PINNED_CERT. Do NOT generate a key; restore the release keystore."
echo "Signing key: certificate $KS_CERT (pinned)"
[ -z "$CHECK_ONLY" ] || exit 0

# Build-only Gradle settings: 3 GiB heap instead of 8, two workers, Kotlin
# compiled inside the Gradle JVM (no separate Kotlin daemon outside the heap
# budget), and no daemon left behind.
sed -i '/^org\.gradle\.jvmargs=/d' "$GRADLE_PROPS"
cat >> "$GRADLE_PROPS" <<'EOF'
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g -XX:ReservedCodeCacheSize=256m
org.gradle.workers.max=2
org.gradle.daemon=false
kotlin.compiler.execution.strategy=in-process
EOF

# key.properties is read with java.util.Properties, so values are escaped for
# it. Values come in through the environment, never argv.
WROTE_KEY_PROPS=1
KS_FILE="$KEYSTORE" KS_PASS="$STORE_PASSWORD" K_ALIAS="$KEY_ALIAS" K_PASS="$KEY_PASSWORD" OUT="$KEY_PROPS" \
  python3 -I -c '
import os
def esc(v):
    out = []
    for i, c in enumerate(v):
        if c == "\\": out.append("\\\\")
        elif c in "\t\n\r\f": out.append({"\t": "\\t", "\n": "\\n", "\r": "\\r", "\f": "\\f"}[c])
        elif c in " #!=:" and i == 0: out.append("\\" + c)
        elif " " <= c <= "~": out.append(c)
        else:
            b = c.encode("utf-16-be")
            out.extend("\\u%02x%02x" % (b[j], b[j + 1]) for j in range(0, len(b), 2))
    return "".join(out)
e = os.environ
fd = os.open(e["OUT"], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="ascii") as f:
    for k, v in (("storeFile", "KS_FILE"), ("storePassword", "KS_PASS"),
                 ("keyAlias", "K_ALIAS"), ("keyPassword", "K_PASS")):
        f.write("%s=%s\n" % (k, esc(e[v])))
'
unset STORE_PASSWORD KEY_PASSWORD KEY_ALIAS
# Build outputs get the usual permissions; the secret files already exist.
umask "$BUILD_UMASK"

# Every process of the build lives in this scope; past MemoryMax the kernel
# kills it rather than pushing the host into thrashing (no swap either).
capped() { systemd-run --user --scope --quiet -p MemoryMax="$MEMORY_MAX" -p MemorySwapMax=0 -- "$@"; }

capped "$FLUTTER" pub get --enforce-lockfile
# --split-per-abi keeps upstream's per-ABI versionCode (base*10+2 for arm64),
# so later builds keep upgrading in place. Debug symbols go under build/.
capped "$FLUTTER" build apk --release --split-per-abi --target-platform android-arm64 \
  --split-debug-info=build/app/outputs/symbols ||
  die "build failed (if it was OOM-killed under MemoryMax=$MEMORY_MAX, see 'journalctl --user -n 50')"

# The key is no longer needed: shred it before verifying.
trap - EXIT INT TERM
cleanup

# --- Verify -------------------------------------------------------------------
[ -f "$APK" ] || die "expected $APK was not produced"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { git status --short --untracked-files=no; echo "WARNING: the build changed tracked files"; }

BT="$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)"
CERTS="$("$BT/apksigner" verify --print-certs "$APK")" || die "$APK does not verify"
APK_CERT="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<<"$CERTS")"
[ -n "$APK_CERT" ] || die "$APK is not signed"
! grep -q '^Signer #2' <<<"$CERTS" || die "$APK has more than one signer"
[ "$APK_CERT" = "$KS_CERT" ] || die "signer $APK_CERT does not match the release keystore ($KS_CERT)"
[ "$APK_CERT" = "$PINNED_CERT" ] || die "signer $APK_CERT is not the pinned release certificate $PINNED_CERT"

echo ""
echo "APK:         $ROOT/$APK"
echo "SHA-256:     $(sha256sum "$APK" | cut -d' ' -f1)"
echo "Signer cert: $APK_CERT (pinned release key)"
echo "Serve it:    bash .claude/skills/serve-apks/scripts/start.sh"
