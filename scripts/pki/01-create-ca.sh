#!/usr/bin/env bash
# Root-CA für die Lab-Umgebung erstellen
set -euo pipefail

# Neu erzeugte Dateien nur für den aktuellen User lesbar machen
umask 077

CA_KEY="ca.key"
CA_CRT="ca.crt"
CA_EXT="ca_ext.cnf"

# Nicht versehentlich eine bestehende CA überschreiben
if [[ -f "$CA_KEY" ]]; then
  echo "Fehler: $CA_KEY existiert bereits." >&2
  echo "Bitte löschen oder umbenennen und erneut ausführen." >&2
  exit 1
fi

# CA-Private-Key erzeugen
openssl genrsa -out "$CA_KEY" 4096
chmod 600 "$CA_KEY"

# Extension-Datei für die CA erstellen
cat > "$CA_EXT" <<EOF
[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

# Selbstsigniertes CA-Zertifikat erzeugen
openssl req -x509 -new -nodes \
  -key "$CA_KEY" \
  -sha256 \
  -days 3650 \
  -subj "/CN=lab-ca" \
  -extensions v3_ca \
  -extfile "$CA_EXT" \
  -out "$CA_CRT"

# Temporäre Extension-Datei entfernen
rm -f "$CA_EXT"

echo "CA erstellt:"
echo "  $CA_KEY"
echo "  $CA_CRT"