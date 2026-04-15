#!/usr/bin/env bash
# Prometheus mTLS-Client-Zertifikat ausstellen
set -euo pipefail
umask 077

CA_KEY="ca.key"
CA_CRT="ca.crt"

CLIENT_NAME="prometheus-client"
CLIENT_CN="prometheus.gfn.internal"

KEY="${CLIENT_NAME}.key"
CSR="${CLIENT_NAME}.csr"
CRT="${CLIENT_NAME}.crt"
EXT="${CLIENT_NAME}_ext.cnf"

# CA muss vorhanden sein
if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "Fehler: $CA_KEY oder $CA_CRT nicht gefunden." >&2
  echo "Zuerst 01-create-ca.sh ausführen." >&2
  exit 1
fi

# Client-Private-Key erzeugen
openssl genrsa -out "$KEY" 2048

# CSR mit Client-CN erzeugen
openssl req -new \
  -key "$KEY" \
  -subj "/CN=${CLIENT_CN}" \
  -out "$CSR"

# Erweiterungen für Client-Zertifikat schreiben
cat > "$EXT" <<EOF
[ v3_client ]
subjectAltName = DNS:${CLIENT_CN}
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
EOF

# Client-Zertifikat ausstellen
openssl x509 -req \
  -in "$CSR" \
  -CA "$CA_CRT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out "$CRT" \
  -days 825 \
  -sha256 \
  -extfile "$EXT" \
  -extensions v3_client

# Temporäre Dateien entfernen
rm -f "$CSR" "$EXT"

echo "Ausgestellt:"
echo "  $KEY"
echo "  $CRT"