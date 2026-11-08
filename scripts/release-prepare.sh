#!/bin/bash
# semantic-release prepare: archive a Developer ID-signed (and, with notary credentials,
# notarized) build of the version semantic-release computed; leave dist/NN-Earshot-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: release-prepare.sh <version>}
# CFBundleVersion drives Sparkle's ordering, so it must only ever increase.
build=${EARSHOT_BUILD_NUMBER:?EARSHOT_BUILD_NUMBER required (CI: the workflow run number)}
[[ $build =~ ^[0-9]+$ ]] || { echo "✗ EARSHOT_BUILD_NUMBER must be a positive integer: $build" >&2; exit 1; }
: "${EARSHOT_SIGN_IDENTITY:?EARSHOT_SIGN_IDENTITY required (e.g. Developer ID Application: Name (TEAMID))}"
: "${MCPB_SIGN_KEY:?MCPB_SIGN_KEY required (Developer ID key, PEM; signs the Claude Desktop extension)}"

rm -rf dist build/Earshot.xcarchive
mkdir -p dist
xcodegen generate --quiet
xcodebuild archive -quiet \
    -project Earshot.xcodeproj -scheme Earshot -configuration Release \
    -destination generic/platform=macOS \
    -archivePath build/Earshot.xcarchive \
    -clonedSourcePackagesDirPath build/SourcePackages \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$EARSHOT_SIGN_IDENTITY" OTHER_CODE_SIGN_FLAGS=--timestamp

team=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' build/Earshot.xcarchive/Info.plist)
cat > build/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
<key>teamID</key><string>$team</string>
</dict></plist>
PLIST
# Export re-signs every nested binary (Sparkle's helpers included) with the Developer ID identity.
xcodebuild -exportArchive -quiet -archivePath build/Earshot.xcarchive \
    -exportOptionsPlist build/export.plist -exportPath dist

app="dist/NN Earshot.app"
codesign --verify --deep --strict --verbose=2 "$app"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == "$build" ]] \
    || { echo "✗ CFBundleVersion is not $build" >&2; exit 1; }
[[ -n $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist") ]] \
    || { echo "✗ SUFeedURL is empty: not a Release build" >&2; exit 1; }
signer=$(scripts/verify-mcpb.sh "$app/Contents/Resources/NN Earshot.mcpb")
[[ $signer == "Developer ID Application:"* ]] || { echo "✗ NN Earshot.mcpb signed by $signer, not Developer ID" >&2; exit 1; }

if [[ -n ${NOTARY_KEY:-} ]]; then
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID required with NOTARY_KEY}" "${NOTARY_KEY_ISSUER:?NOTARY_KEY_ISSUER required with NOTARY_KEY}"
    notary="${RUNNER_TEMP:-$TMPDIR}/notary.p8"
    (umask 077; printf '%s' "$NOTARY_KEY" > "$notary")
    ditto -c -k --keepParent "$app" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --key "$notary" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER" --wait
    rm -f "$notary" dist/notarize.zip
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
else
    echo "::warning::NOTARY_KEY_P8 is not set; publishing signed but un-notarized (Gatekeeper will block downloads)"
fi

ditto -c -k --keepParent "$app" "dist/NN-Earshot-$version.zip"
echo "✓ Prepared $version (build $build)"
