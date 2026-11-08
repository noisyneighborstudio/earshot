#!/bin/bash
# semantic-release publish: sign the zip with Sparkle's EdDSA key, upload it and then
# appcast.xml to the R2 bucket behind SUFeedURL (project.yml), and link the download from the
# GitHub release. Zip first, so the enclosure URL resolves before any client can read the appcast.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: publish-appcast.sh <version> <git-tag>}
tag=${2:?git tag required}
build=${EARSHOT_BUILD_NUMBER:?EARSHOT_BUILD_NUMBER required}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY required}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN required (R2 edit on the earshot-releases bucket)}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID required}"
export GH_TOKEN=${GITHUB_TOKEN:?GITHUB_TOKEN required}
bucket=earshot-releases

app="dist/NN Earshot.app"
artifact="dist/NN-Earshot-$version.zip"
[[ -f $artifact ]] || { echo "✗ missing $artifact; prepare did not run" >&2; exit 1; }
info="$app/Contents/Info.plist"
feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")

# Key via stdin: never on disk, never in argv.
sign_update=build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" -f - -p "$artifact")
[[ ${#signature} -eq 88 ]] || { echo "✗ unexpected signature from sign_update" >&2; exit 1; }
# A key that doesn't match the app's SUPublicEDKey makes every client reject the update.
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")
swift scripts/verify-signature.swift "$public_key" "$signature" "$artifact" \
    || { echo "✗ SPARKLE_PRIVATE_KEY does not match SUPublicEDKey" >&2; exit 1; }

put() { # <object> <file> <content-type> <cache-control>
    npx --no-install wrangler r2 object put "$bucket/$1" --remote --file "$2" --content-type "$3" --cache-control "$4"
}

name=$(basename "$artifact")
url="${feed%/*}/$name"
size=$(stat -f %z "$artifact")
# Versioned name, never overwritten: cache it forever.
put "$name" "$artifact" application/zip "public, max-age=31536000, immutable"
got=$(curl -sL --retry 5 --retry-all-errors -o /dev/null -w '%{http_code} %{size_download}' "$url")
[[ $got == "200 $size" ]] || { echo "✗ $url not served whole (got: $got, want: 200 $size)" >&2; exit 1; }

published=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
appcast=$(mktemp)
cat > "$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>NN Earshot Updates</title><item>
<title>NN Earshot $version</title><pubDate>$published</pubDate>
<link>https://github.com/$repo/releases/tag/$tag</link>
<sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
<enclosure url="$url" sparkle:version="$build" sparkle:shortVersionString="$version" length="$size" type="application/octet-stream" sparkle:edSignature="$signature"/>
</item></channel></rss>
XML
# Short cache: clients see a new release within minutes.
put appcast.xml "$appcast" application/xml "public, max-age=300"
rm -f "$appcast"

notes=$(gh release view "$tag" -R "$repo" --json body --jq .body)
gh release edit "$tag" -R "$repo" --notes "$notes

**Download:** [$name]($url)"
echo "✓ Published $version → $feed"
