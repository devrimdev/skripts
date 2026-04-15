#!/usr/bin/env bash
# Root-CA für die Lab-Umgebung erstellen
set -euo pipefail

# Neu erzeugte Dateien nur für den aktuellen User lesbar machen
umask 077

CA_KEY="ca.key"
CA_CRT="ca.crt"

# Nicht versehentlich eine bestehende CA überschreiben
if [[ -f "$CA_KEY" || -f "$CA_CRT" ]]; then
  echo "Fehler: $CA_KEY oder $CA_CRT existiert bereits." >&2
  echo "Bitte löschen oder umbenennen und erneut ausführen." >&2
  exit 1
fi

# CA-Private-Key erzeugen
openssl genrsa -out "$CA_KEY" 4096
chmod 600 "$CA_KEY"

# Selbstsigniertes CA-Zertifikat erzeugen
openssl req -x509 -new -nodes \
  -key "$CA_KEY" \
  -sha256 \
  -days 3650 \
  -subj "/CN=lab-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid,issuer" \
  -out "$CA_CRT"

echo "CA erstellt:"
echo "  $CA_KEY"
echo "  $CA_CRT"