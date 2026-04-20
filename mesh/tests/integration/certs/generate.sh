#!/usr/bin/env bash
# Generate a disposable test CA and a DERP leaf cert for the integration
# harness. Fast (<1 s on GB10), no external dependencies beyond openssl.
#
# derper (manual cert mode) expects files named <hostname>.crt and
# <hostname>.key in its -certdir. We write directly to those names.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERP_HOST="derp.meshtest.local"
DERP_IP="192.168.50.13"
LEAF_CRT="$CERT_DIR/${DERP_HOST}.crt"
LEAF_KEY="$CERT_DIR/${DERP_HOST}.key"

rm -f "$CERT_DIR"/{ca.key,ca.crt,ca.srl} "$LEAF_CRT" "$LEAF_KEY"

openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" \
    -sha256 -days 7 \
    -subj "/CN=Mesh Integration Test CA" \
    -out "$CERT_DIR/ca.crt" 2>/dev/null

openssl genrsa -out "$LEAF_KEY" 2048 2>/dev/null
openssl req -new -key "$LEAF_KEY" \
    -subj "/CN=${DERP_HOST}" \
    -addext "subjectAltName=DNS:${DERP_HOST},IP:${DERP_IP}" \
    -out "$CERT_DIR/derp.csr" 2>/dev/null
openssl x509 -req -in "$CERT_DIR/derp.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$LEAF_CRT" -days 7 -sha256 \
    -extfile <(printf "subjectAltName=DNS:%s,IP:%s" "$DERP_HOST" "$DERP_IP") \
    2>/dev/null
rm -f "$CERT_DIR/derp.csr"

# Self-check: leaf must chain to CA. Fails fast if either file is corrupt.
openssl verify -CAfile "$CERT_DIR/ca.crt" "$LEAF_CRT" >/dev/null

# Windows-side install script. Emitted here (not in run-tests.sh) so cert
# plumbing stays co-located. Deterministic content — regenerating is fine.
# Invoked via `powershell -File` in Phase 4.5 to avoid cross-shell quoting.
cat > "$CERT_DIR/install-ca-and-hosts.ps1" <<PS1
# Install the meshtest test CA into the Windows Root store and register
# a hosts-file entry for the test DERP. Run by Phase 4.5 in run-tests.sh.
#
# Error handling: \$ErrorActionPreference = 'Stop' halts on PowerShell-cmdlet
# errors (covers Add-Content below — it's a cmdlet). It does NOT cover
# native-command non-zero exits, so certutil needs an explicit
# \$LASTEXITCODE check. Do not "simplify" by removing it.
\$ErrorActionPreference = 'Stop'
certutil -addstore -f Root "\$env:USERPROFILE\meshtest-ca.crt"
if (\$LASTEXITCODE -ne 0) {
    throw "certutil exit=\$LASTEXITCODE"
}
Add-Content -Path "\$env:SystemRoot\System32\drivers\etc\hosts" \`
            -Value '${DERP_IP} ${DERP_HOST}'
Write-Host "CA + hosts entry installed OK"
PS1

echo "certs generated: $CERT_DIR (leaf=${DERP_HOST}.crt ca=ca.crt ps1=install-ca-and-hosts.ps1)"
