#!/usr/bin/env bash
#
# release.sh — build, notarise, sign for Sparkle, and deploy a new
# Daisy release to mydaisy.io.
#
# This is the post-launch release flow. Before running it once, do
# the bootstrap steps in scripts/release-bootstrap.md:
#   • Sparkle SPM dependency added in Xcode
#   • EdDSA key pair generated (private in Keychain, public in
#     Info.plist as SUPublicEDKey)
#   • SUFeedURL set to https://mydaisy.io/appcast.xml
#   • Notary credentials stored as a keychain profile named
#     "daisy-notary" via xcrun notarytool store-credentials
#   • Developer ID Application certificate present in the login
#     keychain
#   • Daisy-web repo cloned next to Daisy repo (../Daisy-web)
#
# Usage:
#   ./scripts/release.sh 1.0.1 3
#                        ^^^^^ ^
#                        |     |
#                        |     CFBundleVersion (build number, monotonic)
#                        CFBundleShortVersionString (marketing version)
#
# After this script finishes successfully:
#   1. Inspect public/appcast.xml in Daisy-web — copy the printed
#      <item> block into it (manual paste so you can edit release
#      notes).
#   2. Commit + push Daisy-web.
#   3. Vercel auto-deploys appcast.xml + the new DMG within 1–2 min.
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — adjust if your local paths differ.
# -----------------------------------------------------------------------------

DAISY_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAISY_WEB_REPO="${DAISY_REPO}/../Daisy-web"
SCHEME="Daisy"
CONFIGURATION="Release"
TEAM_ID="${DAISY_TEAM_ID:-LW64FQXZCU}"  # Apple Developer team ID; override via DAISY_TEAM_ID env var
SIGNING_IDENTITY="${DAISY_SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="daisy-notary"
APPCAST_URL="https://mydaisy.io/appcast.xml"
DOWNLOAD_URL_BASE="https://mydaisy.io/downloads"

# -----------------------------------------------------------------------------
# notarise_with_retry <path> <human-label>
#
# `xcrun notarytool submit --wait` can fail mid-flight on Apple's
# gateway (5xx / transient connection drops) without any way for the
# caller to know whether the submission ever reached the server.
# Pre-1.0.3 this aborted the whole release run after 3-5 minutes of
# archive + sign work. Now: 3 attempts with 60s / 180s / 360s backoff.
# On final failure, surface the underlying notarytool exit code and
# log so the user can diagnose.
# -----------------------------------------------------------------------------
notarise_with_retry() {
    local artifact="$1"
    local label="$2"
    local attempt
    local delay
    for attempt in 1 2 3; do
        if xcrun notarytool submit "${artifact}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait; then
            return 0
        fi
        if [[ ${attempt} -lt 3 ]]; then
            case ${attempt} in
                1) delay=60 ;;
                2) delay=180 ;;
                *) delay=360 ;;
            esac
            echo "  ⚠ notarytool failed for ${label} (attempt ${attempt}/3). Retrying in ${delay}s…" >&2
            sleep "${delay}"
        fi
    done
    echo "  ✗ notarytool failed for ${label} after 3 attempts. Aborting." >&2
    return 1
}

# -----------------------------------------------------------------------------
# Args.
# -----------------------------------------------------------------------------

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <marketing-version> <build-number>" >&2
    echo "  e.g.  $0 1.0.1 3" >&2
    exit 1
fi

VERSION="$1"
BUILD="$2"
DMG_NAME="Daisy-${VERSION}.dmg"
ARCHIVE_PATH="${DAISY_REPO}/build/Daisy-${VERSION}.xcarchive"
EXPORT_PATH="${DAISY_REPO}/build/export-${VERSION}"
DMG_PATH="${DAISY_REPO}/build/${DMG_NAME}"
APPCAST_FILE="${DAISY_WEB_REPO}/public/appcast.xml"

echo "▸ Daisy ${VERSION} (build ${BUILD})"
echo "  archive : ${ARCHIVE_PATH}"
echo "  export  : ${EXPORT_PATH}"
echo "  dmg     : ${DMG_PATH}"
echo

# -----------------------------------------------------------------------------
# 0. Sanity — build number must be strictly greater than the highest
#    <sparkle:version> already published in appcast.xml. Sparkle compares
#    items by sparkle:version (CFBundleVersion), not shortVersionString —
#    on 2026-05-20 we shipped 1.0.3 build 6 alongside 1.0.2 build 7 and
#    Sparkle offered our tester a "downgrade" to 1.0.2 because 7 > 6.
#    pbxproj's CURRENT_PROJECT_VERSION is stale (release.sh doesn't bump
#    it), so the authoritative source for "what's the next free build" is
#    appcast.xml itself.
#
#    Failing here costs <1s. Failing in [6/6] would cost 15+ minutes of
#    archive + notary work for a DMG that can't be used.
# -----------------------------------------------------------------------------

if [[ -f "${APPCAST_FILE}" ]]; then
    # Extract every <sparkle:version>N</sparkle:version> integer and take
    # the max. grep -oE keeps the script portable (no xmllint required).
    MAX_PUBLISHED_BUILD=$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "${APPCAST_FILE}" \
        | grep -oE '[0-9]+' \
        | sort -n \
        | tail -1 || true)
    if [[ -n "${MAX_PUBLISHED_BUILD}" && "${BUILD}" -le "${MAX_PUBLISHED_BUILD}" ]]; then
        echo "  ✗ Build ${BUILD} ≤ last published build ${MAX_PUBLISHED_BUILD} in appcast.xml" >&2
        echo "    Sparkle compares items by <sparkle:version> (CFBundleVersion), not by" >&2
        echo "    shortVersionString — clients already on build ${MAX_PUBLISHED_BUILD} won't see" >&2
        echo "    this release, or worse, will be offered an apparent downgrade." >&2
        echo "" >&2
        echo "    Next available build: $((MAX_PUBLISHED_BUILD + 1))" >&2
        echo "    Re-run:   $0 ${VERSION} $((MAX_PUBLISHED_BUILD + 1))" >&2
        exit 1
    fi
    if [[ -n "${MAX_PUBLISHED_BUILD}" ]]; then
        echo "  ✓ Build ${BUILD} > last published ${MAX_PUBLISHED_BUILD} (appcast.xml)"
        echo
    fi
fi

# -----------------------------------------------------------------------------
# 1. Archive — release-config build of the Xcode project.
# -----------------------------------------------------------------------------

echo "▸ [1/6] xcodebuild archive…"
rm -rf "${ARCHIVE_PATH}"
xcodebuild \
    -project "${DAISY_REPO}/Daisy.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD}" \
    archive
echo

# -----------------------------------------------------------------------------
# 2. Export — pull Daisy.app out of the archive with Developer ID
#    signing and post-export notarisation prep.
# -----------------------------------------------------------------------------

echo "▸ [2/6] exporting Daisy.app from archive…"
rm -rf "${EXPORT_PATH}"
EXPORT_OPTIONS="${DAISY_REPO}/build/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
</dict>
</plist>
EOF
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}"
APP_PATH="${EXPORT_PATH}/Daisy.app"
echo "  → ${APP_PATH}"
echo

# -----------------------------------------------------------------------------
# 3. Notarise — submit Daisy.app to Apple, wait, then staple the
#    ticket so it works offline.
# -----------------------------------------------------------------------------

echo "▸ [3/6] notarising Daisy.app… (this can take a few minutes)"
ZIP_FOR_NOTARY="${EXPORT_PATH}/Daisy-notary.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_FOR_NOTARY}"
notarise_with_retry "${ZIP_FOR_NOTARY}" "Daisy.app"
xcrun stapler staple "${APP_PATH}"
echo "  → notarised + stapled"
echo

# -----------------------------------------------------------------------------
# 4. DMG — create-dmg packages Daisy.app into a signed disk image.
#    Notarise the DMG itself too — required by Sparkle so the
#    in-place install doesn't trip Gatekeeper.
# -----------------------------------------------------------------------------

echo "▸ [4/6] creating DMG…"
# We use `dmgbuild` (Python) instead of `create-dmg` because create-dmg's
# AppleScript-driven layout step silently fails on macOS Sequoia/Tahoe:
# the .background/dmg-background.tiff lands correctly, but the .DS_Store
# ends up missing the BkPa/pict alias, so Finder opens the DMG in
# default view with no branded background. dmgbuild writes .DS_Store
# programmatically via the `ds_store` library — no AppleScript involved.
if ! command -v dmgbuild >/dev/null 2>&1; then
    echo "  ✗ dmgbuild not installed. Run: pip3 install --user dmgbuild" >&2
    echo "    (or: pipx install dmgbuild)" >&2
    exit 1
fi
rm -f "${DMG_PATH}"

# Build a multi-resolution TIFF from the 1× + 2× PNGs so Finder serves
# the @2x variant on retina displays. tiffutil ships with macOS.
DMG_BG_1X="${DAISY_REPO}/scripts/assets/dmg-background.png"
DMG_BG_2X="${DAISY_REPO}/scripts/assets/dmg-background@2x.png"
DMG_BG_TIFF="${DAISY_REPO}/build/dmg-background.tiff"
DMG_BG_DEFINE=()
if [[ -f "${DMG_BG_1X}" && -f "${DMG_BG_2X}" ]]; then
    tiffutil -cathidpicheck "${DMG_BG_1X}" "${DMG_BG_2X}" -out "${DMG_BG_TIFF}" >/dev/null
    DMG_BG_DEFINE=(-D "background=${DMG_BG_TIFF}")
else
    echo "  ⚠ scripts/assets/dmg-background{,@2x}.png missing — falling back to plain DMG" >&2
fi

# Pass only Daisy.app via the dmgbuild settings — see
# scripts/dmgbuild_settings.py. We deliberately do NOT include the whole
# export directory, otherwise xcodebuild's exportArchive byproducts
# (DistributionSummary.plist, ExportOptions.plist, Packaging.log) and
# our notary ZIP would all show up in the DMG window.
DMG_SETTINGS="${DAISY_REPO}/scripts/dmgbuild_settings.py"
dmgbuild \
    -s "${DMG_SETTINGS}" \
    -D "app_path=${APP_PATH}" \
    "${DMG_BG_DEFINE[@]}" \
    "Daisy ${VERSION}" \
    "${DMG_PATH}"

# dmgbuild doesn't sign the DMG — do it ourselves so Gatekeeper accepts
# it post-notarisation. Equivalent to create-dmg's --codesign flag.
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"

echo "▸ [4b/6] notarising DMG…"
notarise_with_retry "${DMG_PATH}" "DMG"
xcrun stapler staple "${DMG_PATH}"
echo "  → ${DMG_PATH}"
echo

# -----------------------------------------------------------------------------
# 5. Sparkle EdDSA signature — required for the appcast item.
# -----------------------------------------------------------------------------

echo "▸ [5/6] signing DMG for Sparkle (EdDSA)…"
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1)"
if [[ -z "${SIGN_UPDATE}" ]]; then
    # Fallback — Sparkle ships sign_update inside the framework. If
    # SPM hasn't built it yet, the user can download the release
    # archive from github.com/sparkle-project/Sparkle/releases.
    SIGN_UPDATE="$(command -v sign_update || true)"
fi
if [[ -z "${SIGN_UPDATE}" ]]; then
    echo "  ✗ sign_update not found. Build Daisy once after adding Sparkle SPM dep," >&2
    echo "    OR download Sparkle release archive and add bin/ to PATH." >&2
    exit 1
fi
SIGNATURE_OUTPUT="$("${SIGN_UPDATE}" "${DMG_PATH}")"
DMG_LENGTH=$(stat -f%z "${DMG_PATH}")
echo "  → ${SIGNATURE_OUTPUT}"
echo "  → length ${DMG_LENGTH} bytes"
echo

# -----------------------------------------------------------------------------
# 6. Publish — copy DMG to Daisy-web, build the appcast <item> from the
#    release-notes markdown, inject it into public/appcast.xml, and
#    commit. Push is gated behind DAISY_AUTO_PUSH=1 so you get a chance
#    to review the commit before it goes live.
# -----------------------------------------------------------------------------

echo "▸ [6/6] publishing to Daisy-web…"

NOTES_MD="${DAISY_REPO}/scripts/release-notes/${VERSION}.md"
if [[ ! -f "${NOTES_MD}" ]]; then
    echo "  ✗ Release notes missing: ${NOTES_MD}" >&2
    echo "    Create the file with markdown bullets (one '- text' per line)," >&2
    echo "    then re-run this script. The heading and any prose are ignored;" >&2
    echo "    only '- ' / '* ' bullets are picked up." >&2
    exit 1
fi

mkdir -p "${DAISY_WEB_REPO}/public/downloads"
cp "${DMG_PATH}" "${DAISY_WEB_REPO}/public/downloads/${DMG_NAME}"
echo "  → DMG copied: public/downloads/${DMG_NAME}"

# APPCAST_FILE defined at top — used here for inject step.
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

VERSION="${VERSION}" \
BUILD="${BUILD}" \
PUBDATE="${PUBDATE}" \
DOWNLOAD_URL="${DOWNLOAD_URL_BASE}/${DMG_NAME}" \
SIGNATURE_LINE="${SIGNATURE_OUTPUT}" \
NOTES_MD="${NOTES_MD}" \
APPCAST_FILE="${APPCAST_FILE}" \
python3 <<'PY'
import os, re, html, pathlib, sys

version       = os.environ["VERSION"]
build         = os.environ["BUILD"]
pubdate       = os.environ["PUBDATE"]
download_url  = os.environ["DOWNLOAD_URL"]
signature     = os.environ["SIGNATURE_LINE"].strip()
notes_path    = pathlib.Path(os.environ["NOTES_MD"])
appcast_path  = pathlib.Path(os.environ["APPCAST_FILE"])

# --- Convert markdown bullets to HTML <li> -----------------------------
bullets = []
for raw in notes_path.read_text(encoding="utf-8").splitlines():
    stripped = raw.lstrip()
    if stripped.startswith(("- ", "* ")):
        text = stripped[2:].rstrip()
        # Escape HTML, then keep simple `code` spans readable
        safe = html.escape(text)
        bullets.append(f"          <li>{safe}</li>")
if not bullets:
    print(f"  ✗ No bullet lines found in {notes_path.name}", file=sys.stderr)
    sys.exit(1)
notes_html = "\n".join(bullets)

# --- Build the new <item> block ----------------------------------------
item_block = f"""    <item>
      <title>Daisy {version}</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h3>What's new in {version}</h3>
        <ul>
{notes_html}
        </ul>
      ]]></description>
      <enclosure
        url="{download_url}"
        {signature}
        type="application/octet-stream" />
    </item>"""

content = appcast_path.read_text(encoding="utf-8")

# On the very first real publish, strip the placeholder template comment
# *before* the idempotency check — otherwise the dummy <title>Daisy 1.0.1</title>
# inside the comment trips the "already published" path.
content = re.sub(
    r"\n[ \t]*<!--\s*\n[ \t]*Template item — REMOVE.*?-->\n",
    "\n",
    content,
    count=1,
    flags=re.DOTALL,
)

# Idempotency — if an <item> for this shortVersion is already in the
# appcast, REPLACE it (new build / new length / new edSignature / new
# pubDate / new release notes). Pre-1.0.3 we silently skipped, which
# left appcast pointing at the old build's enclosure metadata while
# the DMG file on disk had been overwritten with the new build —
# producing an EdDSA-signature mismatch that Sparkle silently rejects.
#
# Match the existing <item> block by its <title>Daisy {version}</title>
# and replace the whole block (between `<item>` and `</item>` lines)
# with the freshly-built item_block.
item_re = re.compile(
    r"[ \t]*<item>\s*\n[ \t]*<title>Daisy "
    + re.escape(version)
    + r"</title>.*?</item>\s*\n",
    re.DOTALL,
)
if item_re.search(content):
    new_content = item_re.sub(item_block + "\n", content, count=1)
    appcast_path.write_text(new_content, encoding="utf-8")
    print(f"  ↻ Replaced existing <item> for Daisy {version} (build {build})")
    sys.exit(0)

sentinel = "  </channel>"
if sentinel not in content:
    print(f"  ✗ Couldn't find {sentinel!r} in appcast.xml — aborting", file=sys.stderr)
    sys.exit(1)

new_content = content.replace(sentinel, item_block + "\n\n" + sentinel, 1)
appcast_path.write_text(new_content, encoding="utf-8")
print(f"  ✓ Injected <item> for Daisy {version} into appcast.xml")
PY

# Update the "Download for Mac" button target so the website CTA
# always points at the freshly-published DMG. Source of truth lives
# at Daisy-web/lib/latestVersion.ts; Hero.tsx and Download.tsx import
# from there. Synced with appcast.xml in the same commit so the
# Sparkle-update path (existing users) and the fresh-download path
# (new users from mydaisy.io) can't drift apart.
LATEST_VERSION_FILE="${DAISY_WEB_REPO}/lib/latestVersion.ts"
if [[ -f "${LATEST_VERSION_FILE}" ]]; then
    cat > "${LATEST_VERSION_FILE}" <<EOF
// AUTO-GENERATED by /Users/ca33u/Develop/Daisy/scripts/release.sh on each
// release. Do not hand-edit — \`release.sh\` overwrites the whole file as
// part of step [6/6] right after appcast.xml is updated.
//
// Imported by:
//   - components/Hero.tsx       — "Download for Mac" CTA
//   - components/Download.tsx   — closing-CTA Download button
//
// The single source of truth for "what version does mydaisy.io's
// Download button point at right now" lives here. appcast.xml is the
// source of truth for Sparkle update prompts (existing users); this
// file is the source of truth for fresh downloads (new users).
//
// Keeping them in sync is the responsibility of release.sh — both are
// rewritten in step [6/6] from the same VERSION argument.

export const LATEST_VERSION = "${VERSION}";
export const LATEST_DMG_URL = \`/downloads/Daisy-\${LATEST_VERSION}.dmg\`;
EOF
    echo "  ✓ Rewrote lib/latestVersion.ts → ${VERSION}"
else
    echo "  ⊘ lib/latestVersion.ts not found — skipping (web Hero/Download CTAs may serve a stale link)"
fi

(
    cd "${DAISY_WEB_REPO}"
    git add public/appcast.xml "public/downloads/${DMG_NAME}" lib/latestVersion.ts
    if git diff --staged --quiet; then
        echo "  ⊘ nothing to commit in Daisy-web (already published?)"
    else
        git commit -m "release: Daisy ${VERSION} (build ${BUILD})" >/dev/null
        echo "  ✓ committed: release: Daisy ${VERSION} (build ${BUILD})"
        if [[ "${DAISY_AUTO_PUSH:-0}" == "1" ]]; then
            git push
            echo "  ✓ pushed Daisy-web — Vercel deploys in 1-2 min"
        else
            echo "    Review: cd ${DAISY_WEB_REPO} && git show HEAD"
            echo "    Push:   cd ${DAISY_WEB_REPO} && git push"
            echo "    (or rerun with DAISY_AUTO_PUSH=1 to push automatically)"
        fi
    fi
)

echo
echo "────────────────────────────────────────────────────────────────"
echo "  ✓ Daisy ${VERSION} (build ${BUILD}) released."
echo "    DMG    : ${DMG_PATH}"
echo "    Length : ${DMG_LENGTH} bytes"
echo "    Item   : injected into appcast.xml"
echo "────────────────────────────────────────────────────────────────"
