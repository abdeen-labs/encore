#!/bin/bash
# Builds a distributable Encore: archive → embed the Python runtime and sign it inside-out → sign the app →
# notarise and staple the app → DMG (or zip) → sign, notarise and staple the DMG.
#
#   Scripts/release.sh --notary-profile <keychain profile> [--identity "Developer ID Application: …"] [--zip]
#   Scripts/release.sh --no-notarize      # everything up to notarisation (a locally signed, hardened build)
#
# One-time notary setup (stores credentials in the keychain under a profile name):
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific password>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
IDENTITY=""; PROFILE=""; NOTARIZE=1; FORMAT="dmg"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        --notary-profile) PROFILE="$2"; shift 2 ;;
        --no-notarize) NOTARIZE=0; shift ;;
        --zip) FORMAT="zip"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)"
fi
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
TEAM="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$IDENTITY")"
if [[ $NOTARIZE == 1 && -z "$PROFILE" ]]; then
    echo "Pass --notary-profile <name> (see the header of this script), or --no-notarize." >&2; exit 2
fi
[[ -x "$ROOT/PythonHelper/.runtime/python/bin/python3" ]] \
    || { echo "Run Scripts/setup-python-runtime.sh first." >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }
notarize() {  # <file>
    step "Notarising $(basename "$1") (this waits for Apple)"
    local result id
    result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)" || true
    echo "$result"
    id="$(/usr/bin/plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
    if [[ "$(/usr/bin/plutil -extract status raw - <<<"$result" 2>/dev/null)" != "Accepted" ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
        echo "Notarisation failed." >&2; exit 1
    fi
}

rm -rf "$OUT"; mkdir -p "$OUT"
ARCHIVE="$OUT/Encore.xcarchive"; APP="$OUT/Encore.app"

step "Archiving (Release, $IDENTITY)"
xcodebuild -project "$ROOT/Encore.xcodeproj" -scheme Encore -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -derivedDataPath "$ROOT/build/release-dd" -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
    archive 2>&1 | grep -E "error:|warning: .*Python|\*\* ARCHIVE" || true
[[ -d "$ARCHIVE/Products/Applications/Encore.app" ]] || { echo "Archive failed." >&2; exit 1; }
ditto "$ARCHIVE/Products/Applications/Encore.app" "$APP"

step "Embedding the Python runtime and signing it (inside-out, hardened, timestamped)"
"$ROOT/Scripts/embed-python-runtime.sh" "$APP" "$IDENTITY"

step "Signing Encore.app"
ENTITLEMENTS="$OUT/Encore.entitlements"
codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS" 2>/dev/null || true
[[ -s "$ENTITLEMENTS" ]] && ENT_ARGS=(--entitlements "$ENTITLEMENTS") || ENT_ARGS=()
codesign --force --sign "$IDENTITY" --options runtime --timestamp ${ENT_ARGS[@]+"${ENT_ARGS[@]}"} "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

step "Smoke test: the signed app's Python helper starts and reports its engines"
HELLO="$(printf '{"id":1,"op":"hello"}\n{"id":2,"op":"shutdown"}\n' | env -i HOME="$HOME" HF_HUB_OFFLINE=1 \
    PYTHONPATH="$APP/Contents/Resources/PythonHelper" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
    "$APP/Contents/Resources/python/bin/python3" -s -B -m encore_helper 2>/dev/null | head -1)"
grep -q '"ok":true' <<<"$HELLO" || { echo "The bundled helper didn't start: $HELLO" >&2; exit 1; }
echo "$HELLO" | cut -c1-300

if [[ $NOTARIZE == 1 ]]; then
    ZIP="$OUT/Encore-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    rm -f "$ZIP"
    step "Stapling Encore.app"
    xcrun stapler staple "$APP"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
if [[ "$FORMAT" == "zip" ]]; then
    PACKAGE="$OUT/Encore-$VERSION.zip"
    step "Packaging $(basename "$PACKAGE")"
    ditto -c -k --keepParent "$APP" "$PACKAGE"
else
    PACKAGE="$OUT/Encore-$VERSION.dmg"
    step "Packaging $(basename "$PACKAGE")"
    STAGE="$OUT/dmg"; mkdir -p "$STAGE"; ditto "$APP" "$STAGE/Encore.app"; ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname Encore -srcfolder "$STAGE" -ov -format ULFO "$PACKAGE"
    rm -rf "$STAGE"
    codesign --force --sign "$IDENTITY" --timestamp "$PACKAGE"
    if [[ $NOTARIZE == 1 ]]; then
        notarize "$PACKAGE"
        step "Stapling $(basename "$PACKAGE")"
        xcrun stapler staple "$PACKAGE"
    fi
fi

step "Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP" || true
[[ "$FORMAT" == "dmg" ]] && { spctl --assess --type open --context context:primary-signature --verbose=2 "$PACKAGE" || true; }
du -sh "$APP" "$PACKAGE"
if [[ $NOTARIZE == 0 ]]; then
    echo; echo "Stopped before notarisation (--no-notarize): $PACKAGE is signed but not notarised or stapled."
fi
