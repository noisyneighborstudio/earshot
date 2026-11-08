#!/bin/bash
# semantic-release publish: sign the zip with Sparkle's EdDSA key, upload it to the release,
# then push appcast.xml to the `appcasts` branch (the SUFeedURL in project.yml). Zip first, so
# the enclosure URL resolves before any client can read the appcast. Both must be readable
# without credentials: Sparkle never authenticates.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: publish-appcast.sh <version> <git-tag>}
tag=${2:?git tag required}
build=${EARSHOT_BUILD_NUMBER:?EARSHOT_BUILD_NUMBER required}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY required}"
export GH_TOKEN=${GITHUB_TOKEN:?GITHUB_TOKEN required}

app="dist/NN Earshot.app"
artifact="dist/NN-Earshot-$version.zip"
[[ -f $artifact ]] || { echo "✗ missing $artifact; prepare did not run" >&2; exit 1; }
info="$app/Contents/Info.plist"
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")

# Key via stdin: never on disk, never in argv.
sign_update=build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" -f - -p "$artifact")
[[ ${#signature} -eq 88 ]] || { echo "✗ unexpected signature from sign_update" >&2; exit 1; }
# A key that doesn't match the app's SUPublicEDKey makes every client reject the update.
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")
swift scripts/verify-signature.swift "$public_key" "$signature" "$artifact" \
    || { echo "✗ SPARKLE_PRIVATE_KEY does not match SUPublicEDKey" >&2; exit 1; }

gh release upload "$tag" -R "$repo" --clobber "$artifact"
name=$(basename "$artifact")
url="https://github.com/$repo/releases/download/$tag/$name"
# A fresh asset can answer 504 for minutes, and clients fetch it as soon as the appcast names
# it. Wait until it downloads whole three times running.
size=$(stat -f %z "$artifact") served=0 got=""
for _ in $(seq 1 60); do
    got=$(curl -sL -o /dev/null -w '%{http_code} %{size_download}' "$url" || true)
    if [[ $got == "200 $size" ]]; then
        served=$((served + 1)); (( served >= 3 )) && break
    else
        served=0
    fi
    sleep 20
done
(( served >= 3 )) || { echo "✗ $url still not downloadable after 20 min (last: $got)" >&2; exit 1; }

# Token as a header from the environment: out of argv, out of .git/config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
remote="https://github.com/$repo.git"
publication=$(mktemp -d)
if [[ -n $(git ls-remote --heads "$remote" appcasts) ]]; then
    git clone --quiet --depth 1 --branch appcasts "$remote" "$publication"
else
    git init --quiet -b appcasts "$publication"
fi
published=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat > "$publication/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>NN Earshot Updates</title><item>
<title>NN Earshot $version</title><pubDate>$published</pubDate>
<link>https://github.com/$repo/releases/tag/$tag</link>
<sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
<enclosure url="$url" sparkle:version="$build" sparkle:shortVersionString="$version" length="$size" type="application/octet-stream" sparkle:edSignature="$signature"/>
</item></channel></rss>
XML
git -C "$publication" add -- appcast.xml
git -C "$publication" -c user.name=github-actions -c user.email=github-actions@github.com \
    commit --quiet -m "Publish $version"
git -C "$publication" push --quiet "$remote" HEAD:appcasts
rm -rf "$publication"
echo "✓ Published $version → https://raw.githubusercontent.com/$repo/appcasts/appcast.xml"
