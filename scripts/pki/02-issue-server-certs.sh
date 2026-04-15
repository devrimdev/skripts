#!/usr/bin/env bash
# Server-Zertifikate für alle Hosts ausstellen (ausführlich dokumentiert)
# Dieses Skript läuft auf der PKI-VM und erzeugt für jede Host-Identität
# einen privaten Schlüssel, einen CSR und signiert diesen mit der lokalen CA.
set -euo pipefail
umask 077

# CA-Dateien (müssen auf der PKI-VM existieren)
CA_KEY="ca.key"
CA_CRT="ca.crt"
ISSUED_CSV="issued_certs.csv"

# Hosts, für die Server-Zertifikate erstellt werden
HOSTS=(monitoring pcap analysis mintclient pfsense bastion pki)

# Prüfen, ob CA vorhanden ist
if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "Fehler: $CA_KEY oder $CA_CRT nicht gefunden." >&2
  echo "Zuerst 01-create-ca.sh ausführen." >&2
  exit 1
fi

# CSV-Header nur einmal anlegen
if [[ ! -f "$ISSUED_CSV" ]]; then
  echo "name,expires" > "$ISSUED_CSV"
fi

for HOST in "${HOSTS[@]}"; do
  KEY="${HOST}.key"
  CSR="${HOST}.csr"
  CRT="${HOST}.crt"
  EXT="${HOST}_ext.cnf"

  # Privaten Schlüssel erzeugen
  openssl genrsa -out "$KEY" 2048

  # CSR mit FQDN als CN erzeugen
  openssl req -new \
    -key "$KEY" \
    -subj "/CN=${HOST}.gfn.internal" \
    -out "$CSR"

  # Warnung, falls Zertifikat bereits existiert
  if [[ -f "$CRT" ]]; then
    echo "Warnung: $CRT existiert bereits. Wird überschrieben." >&2
  fi

  # OpenSSL-Erweiterungen für Server-Zertifikat schreiben (SAN + EKU)
  cat > "$EXT" <<EOF
[ v3_srv ]
basicConstraints = critical, CA:FALSE
subjectAltName = DNS:${HOST}.gfn.internal
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

  # Zertifikat signieren
  openssl x509 -req \
    -in "$CSR" \
    -CA "$CA_CRT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -out "$CRT" \
    -days 825 \
    -sha256 \
    -extfile "$EXT" \
    -extensions v3_srv

  # Ablaufdatum ermitteln und CSV aktualisieren
  END_DATE="$(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2)"
  if grep -q "^${HOST}," "$ISSUED_CSV"; then
    sed -i -E "s|^${HOST},.*|${HOST},${END_DATE}|" "$ISSUED_CSV"
  else
    printf '%s,%s\n' "$HOST" "$END_DATE" >> "$ISSUED_CSV"
  fi

  # Temporäre Dateien entfernen
  rm -f "$CSR" "$EXT"

  echo "Ausgestellt: $CRT"
done

echo
echo "Fertig. Übersicht: $ISSUED_CSV"