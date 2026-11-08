#!/bin/bash
# Checks NN Earshot.mcpb's signature: content digest, signer, and chain (system trust, code signing),
# and prints the signer. `mcpb verify` can't: node-forge's PKCS#7 verify is a stub
# (github.com/modelcontextprotocol/mcpb/issues/277), so it reports every bundle unsigned.
set -euo pipefail
mcpb=${1:?usage: verify-mcpb.sh <file.mcpb>}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# mcpb's sign.js appends: MCPB_SIG_V1, u32 LE length, PKCS#7 (DER, detached), MCPB_SIG_END.
/usr/bin/python3 -I - "$mcpb" "$tmp" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
start = data.rfind(b"MCPB_SIG_V1")
if start < 0 or not data.endswith(b"MCPB_SIG_END"):
    sys.exit("✗ not signed")
(length,) = struct.unpack_from("<I", data, start + 11)
open(sys.argv[2] + "/content", "wb").write(data[:start])
open(sys.argv[2] + "/signature.der", "wb").write(data[start + 15:start + 15 + length])
PY
# Chain trust is checked below, against the macOS store like Claude Desktop.
/usr/bin/openssl smime -verify -binary -inform DER -in "$tmp/signature.der" -content "$tmp/content" \
    -noverify -out /dev/null 2>/dev/null || { echo "✗ signature doesn't match the bundle" >&2; exit 1; }
/usr/bin/openssl pkcs7 -inform DER -in "$tmp/signature.der" -print_certs -out "$tmp/chain.pem"
security verify-cert -c "$tmp/chain.pem" -p codeSign >/dev/null || { echo "✗ signer isn't trusted for code signing" >&2; exit 1; }
/usr/bin/openssl x509 -in "$tmp/chain.pem" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= //p'
