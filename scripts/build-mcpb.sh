#!/bin/bash
# Builds NN Earshot.mcpb, the Claude Desktop extension (github.com/modelcontextprotocol/mcpb), from
# Earshot/Extension. Runs as an Earshot build phase; Install in Settings opens the bundled copy.
# With MCPB_SIGN_CERT + MCPB_SIGN_KEY (PEM, Developer ID; CI) it's signed, so Claude Desktop names the publisher.
set -euo pipefail
out=${1:?usage: build-mcpb.sh <out.mcpb> <version>}
version=${2:?version required}
root="$(cd "$(dirname "$0")/.." && pwd)"
ext="$root/Earshot/Extension"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/server"
cp "$ext/manifest.json" "$stage/manifest.json"
plutil -replace version -string "$version" "$stage/manifest.json"
install -m 755 "$ext/earshot" "$stage/server/earshot"
cp "$root/Earshot/Support/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" "$stage/icon.png"

rm -f "$out"
ditto -c -k --norsrc "$stage" "$out"
if [[ -n ${MCPB_SIGN_KEY:-} ]]; then
    : "${MCPB_SIGN_CERT:?MCPB_SIGN_CERT required with MCPB_SIGN_KEY}"
    "$root/node_modules/.bin/mcpb" sign "$out" --cert "$MCPB_SIGN_CERT" --key "$MCPB_SIGN_KEY" \
        --intermediate "$ext/DeveloperIDCA.pem"
fi
