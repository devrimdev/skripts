# Teil X: Hardening – Konsistenzdurchsetzung (Nachzug)

## Grundkonzept

Die Kapitel 07–09 haben die Observability-Schicht funktional aufgebaut:

* **MonitoringVM (.20)** – Zeitreihenanalyse mit Prometheus und Grafana
* **CaptureVM (.21)** – Wire-Level-Debugging mit `tcpdump`
* **AnalysisVM (.22)** – aktiver Messpunkt für NTP-Offset, DNS-Antwortzeiten und ICMP-Erreichbarkeit

Diese Systeme arbeiten bereits mit klar definierten Rollen und wurden bewusst lokal sowie schrittweise gehärtet. Jedes Kapitel dokumentierte die jeweilige VM als eigenständige, nachvollziehbare Einheit und erfüllte damit den Lernzweck des isolierten Infrastrukturaufbaus.

Mit Abschluss dieser Phase bleiben jedoch bewusst einige logische Querverbindungen offen, die sich erst aus der Chronologie des Gesamtaufbaus ergeben: Prometheus benötigt am Ende verifizierbare Identitäten per mTLS, dafür wird eine dedizierte CA-Instanz benötigt; die sichere Verteilung dieses Schlüsselmaterials verlangt einen eindeutig definierten SSH-Verwaltungspfad; die spätere Umstellung auf Hostnamen setzt konsistente DNS-Overrides voraus.

Genau diese zusammenhängenden Nachzüge bündelt dieses Kapitel. Es konsolidiert die offenen Punkte des abgeschlossenen Aufbaus und überführt die Observability-Schicht in einen konsistenten Endzustand: ihre Einsatzbereitschaft als vertrauenswürdige Akteursschicht für die Phase 5 – Infrastructure Enforcement by Observability.

Die Umsetzung folgt dieser Reihenfolge:

* Sicherstellung eines funktionierenden Admin-Zugangs über RDP über VPN vom Schulcomputer direkt zur `mint-machine`
* Einführung einer **Bastion (.99)** als zentraler und erzwungener SSH-Verwaltungspfad
* Aufbau einer dedizierten **PKI-VM (.199)** zur Erstellung einer CA und zur Zertifikatsausstellung
* Einrichtung konsistenter DNS Host Overrides für hostnamenbasierte Kommunikation
* Verteilung und strukturierte Ablage von Zertifikaten auf allen relevanten Systemen
* Umstellung der Exporter und Blackbox-Komponenten auf mTLS
* Absicherung von pfSense und Prometheus über TLS
* Bereinigung und Finalisierung von Firewall- und DHCP-Konfiguration

---

## Schritt 1 – Admin-Zugang auf mintclient dokumentieren (XRDP)

In `01-firewall.md` wurde für TCP-Port 3389 eine Portweiterleitung auf `mintclient` eingerichtet. Was dort nicht dokumentiert wurde, ist der dazugehörige RDP-Dienst auf dem Zielsystem selbst.

Eine Portweiterleitung stellt ausschließlich den Netzwerkpfad bereit – ohne aktiven RDP-Dienst wird die Verbindung zwar weitergeleitet, dort jedoch nicht angenommen.

Damit entsteht eine Lücke in der bisherigen Dokumentation: Wer die Kapitel von vorne durcharbeitet, hätte nach `01-firewall.md` keinen funktionierenden RDP-Zugang auf `mintclient` erhalten. Dieser Schritt schließt diese Lücke.

Der direkte Pfad `Schulcomputer → VPN → RDP → mintclient` ist nicht mehr als Komfortfunktion zu verstehen, sondern als die definierte Admin-Schnittstelle für alle weiteren Schritte dieses Kapitels. Der Pfad `Schulcomputer → VPN → RDP → Windows Server 2019 Datacenter → Hyper-V Manager → mintclient` bleibt davon unberührt und erfüllt weiterhin wichtige Eingriffsfunktionen – auch ins Firmennetzwerk.

### 1.1 – XFCE und xrdp installieren

```bash
sudo apt install -y xrdp xfce4 xfce4-goodies
```

> `xrdp` allein liefert keinen Desktop. Ohne Desktop-Umgebung zeigt jede RDP-Verbindung nur einen schwarzen Bildschirm.

### 1.2 – XFCE als Session festlegen

```bash
echo xfce4-session > ~/.xsession
chmod +x ~/.xsession
```

### 1.3 – Zugriff auf RDP-Benutzer einschränken

```bash
sudo groupadd rdpusers
sudo usermod -aG rdpusers student
```

```bash
sudo nano /etc/xrdp/sesman.ini
```

```ini
TerminalServerUsers=rdpusers
```

> Nur Benutzer in der Gruppe `rdpusers` können sich per RDP anmelden.

### 1.4 – xrdp Zugriff auf SSL-Zertifikat erlauben

```bash
sudo adduser xrdp ssl-cert
```

### 1.5 – Session-Auflösung in `startwm.sh` anpassen

```bash
sudo nano /etc/xrdp/startwm.sh
```

Die letzten Zeilen ersetzen durch:

```bash
# User-defined session
if [ -r ~/.xsession ]; then
  exec ~/.xsession
fi

# XFCE fallback
if command -v xfce4-session >/dev/null 2>&1; then
  exec xfce4-session
fi

# Default fallback
test -x /etc/X11/Xsession && exec /etc/X11/Xsession
exec /bin/sh /etc/X11/Xsession
```

### 1.6 – xrdp aktivieren und starten

```bash
sudo systemctl enable xrdp
sudo systemctl restart xrdp
sudo systemctl status xrdp
```

Erwartung: `Active: active (running)`

### 1.7 – RDP zu Admin-Client

Auf dem Hyper-V-Manager `pfsense router` markieren, sodass im unteren Panel die zum `R-LAB_Internet` zugeordnete IP-Adresse sichtbar wird.

[![WAN IP ermitteln](../images/img_104.png)](../images/img_104.png)

```
mstsc /v:192.168.1.10
```

→ student / <Passwort>

[![RDP Verbindung](../images/img_105.png)](../images/img_105.png)

Erwartung: XFCE-Desktopsitzung auf mintclient.

---

## Schritt 2 – Bastion-VM einrichten

### 2.1 – VM erstellen (Hyper-V)

**Hyper-V Manager → Neu → Virtueller Computer**

| Feld | Wert |
| --- | --- |
| Name | `Bastion` |
| OS | Ubuntu Server 24.04 LTS Minimal |
| RAM | 2048 MB |
| CPU | 2 vCPU |
| Disk | 10 GB |
| Netzwerkkarte | `Firmennetzwerk` |

> Ubuntu 24.04 benötigt während des Bootvorgangs und bei `apt upgrade` kurzzeitig deutlich mehr RAM als im Leerlauf. 2048 MB während der Einrichtung verhindert OOM-Kills und hängengebliebene Upgrades. Nach abgeschlossener Einrichtung wird der RAM in Hyper-V auf 512 MB reduziert.

Im Ubuntu-Installer auf der Seite **SSH Setup** die Option **Install OpenSSH server** aktivieren. `openssh-server` muss nicht nachinstalliert werden.

### 2.2 – Basis-Setup

```bash
sudo apt update && sudo apt upgrade -y
sudo hostnamectl set-hostname bastion
sudo apt install -y nano
```

Nach Abschluss aller Einrichtungsschritte in Hyper-V:

**Hyper-V Manager → Bastion → Einstellungen → Arbeitsspeicher → 512 MB → OK**

### 2.3 – Static Mapping in pfSense

MAC-Adresse ermitteln:

```bash
ip link show eth0
```

**Services → DHCP Server → LAN → Static Mappings → + Add**

| Feld | Wert |
| --- | --- |
| MAC Address | MAC von `eth0` der Bastion |
| IP Address | `192.168.10.99` |
| Hostname | `bastion` |
| Description | Bastion |

☑ **Create a static ARP table entry for this MAC & IP Address pair**

→ **Save**

```bash
sudo networkctl renew eth0
ip a show eth0
```

Erwartung: `inet 192.168.10.99/24` zugewiesen.

---

## Schritt 3 – PKI-VM einrichten

### 3.1 – VM erstellen (Hyper-V)

**Hyper-V Manager → Neu → Virtueller Computer**

| Feld | Wert |
| --- | --- |
| Name | `PKI-VM` |
| OS | Ubuntu Server 24.04 LTS Minimal |
| RAM | 2048 MB |
| CPU | 2 vCPU |
| Disk | 10 GB |
| Netzwerkkarte | `Firmennetzwerk` |

> Ubuntu 24.04 benötigt während des Bootvorgangs und bei `apt upgrade` kurzzeitig deutlich mehr RAM als im Leerlauf. 2048 MB während der Einrichtung verhindert OOM-Kills und hängengebliebene Upgrades. Nach abgeschlossener Einrichtung wird der RAM in Hyper-V auf 512 MB reduziert.

Im Ubuntu-Installer auf der Seite **SSH Setup** darf **Install OpenSSH server** unter keinen Umständen aktiviert werden. Die PKI-VM darf keinen `openssh-server` haben – sie ist ausschließlich SSH-Client, empfängt keine eingehenden Verbindungen und wird nur über die Hyper-V-Konsole verwaltet.

### 3.2 – Basis-Setup

```bash
sudo apt update && sudo apt upgrade -y
sudo hostnamectl set-hostname pki
sudo apt install -y openssl openssh-client nano wget
```

Nach Abschluss aller Einrichtungsschritte in Hyper-V:

**Hyper-V Manager → PKI-VM → Einstellungen → Arbeitsspeicher → 512 MB → OK**

### 3.3 – Static Mapping in pfSense

MAC-Adresse ermitteln:

```bash
ip link show eth0
```

**Services → DHCP Server → LAN → Static Mappings → + Add**

| Feld | Wert |
| --- | --- |
| MAC Address | MAC von `eth0` der PKI-VM |
| IP Address | `192.168.10.199` |
| Hostname | `pki` |
| Description | PKI-VM (Offline CA) |

☑ **Create a static ARP table entry for this MAC & IP Address pair**

→ **Save**

```bash
sudo networkctl renew eth0
ip a show eth0
```

Erwartung: `inet 192.168.10.199/24` zugewiesen.

---

## Schritt 4 – DNS Host Overrides für alle VMs

**Services → DNS Resolver → Host Overrides → + Add**

| Host | Domain | IP Address | Description |
| --- | --- | --- | --- |
| `monitoring` | `gfn.internal` | `192.168.10.20` | MonitoringVM |
| `pcap` | `gfn.internal` | `192.168.10.21` | CaptureVM |
| `analysis` | `gfn.internal` | `192.168.10.22` | AnalysisVM |
| `bastion` | `gfn.internal` | `192.168.10.99` | Bastion |
| `pki` | `gfn.internal` | `192.168.10.199` | PKI-VM |

Jeden Eintrag einzeln anlegen: **Save** → am Ende **Apply Changes**

Funktionsnachweis von mintclient:

```bash
nslookup monitoring.gfn.internal
nslookup pcap.gfn.internal
nslookup analysis.gfn.internal
nslookup bastion.gfn.internal
nslookup pki.gfn.internal
```

Erwartung jeweils: `Server: 192.168.10.2`, korrekte IP-Adresse in der Antwort.

---

## Schritt 5 – SSH-Hardening: Bastion als einzige Verwaltungsinstanz

### Policy

* SSH-Passwort-Login ist auf allen VMs deaktiviert.
* Administrative SSH-Zugriffe auf alle Zielsysteme erfolgen ausschließlich über die Bastion.
* Der Zugriffspfad ist fest definiert:

```text
mintclient → Bastion → Zielsysteme (monitoring, pcap, analysis, pki)
```

* Die Zertifikatsverteilung der PKI-VM läuft ebenfalls über die Bastion:

```text
PKI-VM → Bastion → Zielsysteme
```

* `AllowUsers` ist die wirksame Durchsetzungsebene für SSH-Zugriffskontrolle zwischen VMs im selben Subnetz, da pfSense LAN-zu-LAN-Traffic nicht filtert (Layer 2).

### 5.1 – SSH-Keypair auf mintclient erstellen

Auf `mintclient`:

```bash
ssh-keygen -t ed25519 -C "mintclient" -f ~/.ssh/id_ed25519
```

### 5.2 – mintclient-Key auf Bastion hinterlegen

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub student@bastion.gfn.internal
```

Funktionsnachweis:

```bash
ssh student@bastion.gfn.internal 'hostname'
# Erwartung: bastion
```

### 5.3 – SSH-Keypair auf Bastion erstellen

Von der Bastion:

```bash
ssh-keygen -t ed25519 -C "bastion" -f ~/.ssh/id_ed25519
```

### 5.4 – Bastion-Key auf Zielsystemen hinterlegen

Von der Bastion:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub student@monitoring.gfn.internal
ssh-copy-id -i ~/.ssh/id_ed25519.pub student@pcap.gfn.internal
ssh-copy-id -i ~/.ssh/id_ed25519.pub student@analysis.gfn.internal
```

> mintclient hat SSH-Zugriff ausschließlich auf die Bastion als Einstiegspunkt – nicht direkt auf die Zielsysteme. Die Bastion übernimmt den Sprung zu den Zielsystemen. mintclient selbst ist nur über RDP vom Windows-Host erreichbar und erhält im finalen Zustand keinen SSH-Inbound von der Bastion.

> Die PKI-VM hat keinen `openssh-server` und wird ausschließlich über die Hyper-V-Konsole verwaltet. Bastion benötigt daher keinen SSH-Schlüssel auf der PKI-VM.

Funktionsnachweis – Key-Login muss funktionieren **bevor** Passwort-Login deaktiviert wird:

```bash
ssh student@monitoring.gfn.internal 'hostname'
ssh student@pcap.gfn.internal 'hostname'
ssh student@analysis.gfn.internal 'hostname'
```

### 5.5 – SSH-Keypair auf PKI-VM erstellen

Von der PKI-VM:

```bash
ssh-keygen -t ed25519 -C "pki" -f ~/.ssh/id_ed25519
```

### 5.6 – PKI-VM-Key auf Bastion hinterlegen

Den Public Key der PKI-VM manuell auf die Bastion übertragen – da die Bastion noch Passwort-Login erlaubt:

Von der PKI-VM:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub student@bastion.gfn.internal
```

Funktionsnachweis:

```bash
ssh student@bastion.gfn.internal 'hostname'
# Erwartung: bastion
```

### 5.7 – sshd-Hardening auf allen VMs

Auf **Bastion** – erlaubt mintclient und PKI-VM:

```bash
sudo nano /etc/ssh/sshd_config.d/hardening.conf
```

```conf
# /etc/ssh/sshd_config.d/hardening.conf (Bastion)

PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no

# Zugriff nur von definierten Systemen (DNS-gebunden)
AllowUsers student@mintclient.gfn.internal student@pki.gfn.internal

MaxAuthTries 3
LoginGraceTime 30

X11Forwarding no

# Erforderlich für ssh -J (Jump Host), aber eingeschränkt
AllowTcpForwarding local
PermitOpen monitoring.gfn.internal:22 pcap.gfn.internal:22 analysis.gfn.internal:22
PermitTunnel no

# DNS-basierte Zugriffskontrolle aktivieren
UseDNS yes

KbdInteractiveAuthentication no
```

> AllowUsers user@hostname basiert auf Reverse-DNS-Auflösung → pfSense muss als DNS-SSOT konsistente Forward- und Reverse-Auflösung liefern (produktiv wären IP/CIDR-basierte Regeln robuster)
> AllowTcpForwarding local ist notwendig für ssh -J, aber durch PermitOpen auf definierte Ziele begrenzt
> UseDNS yes ist erforderlich, damit SSH den Client-Hostnamen auflöst und gegen AllowUsers prüft

```bash
sudo systemctl restart ssh
```

Auf **monitoring, pcap, analysis** – erlaubt ausschließlich Bastion:

```bash
sudo nano /etc/ssh/sshd_config.d/hardening.conf
```

```conf
# /etc/ssh/sshd_config.d/hardening.conf (monitoring, pcap, analysis)

PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no

# Zugriff nur über Bastion
AllowUsers student@bastion.gfn.internal

MaxAuthTries 3
LoginGraceTime 30

X11Forwarding no
AllowTcpForwarding no
PermitTunnel no

# DNS-basierte Zugriffskontrolle
UseDNS yes

KbdInteractiveAuthentication no
```

> Unterschied zur Bastion:
> Bastion → AllowTcpForwarding local (für ssh -J)
> Zielsysteme → AllowTcpForwarding no (keine Weiterleitung erlaubt)
> verhindert Umgehung der Bastion durch direkte Tunnel
> Zugriff bleibt strikt: mintclient → Bastion → Zielsystem

```bash
sudo systemctl restart ssh
```

> Die PKI-VM hat keinen `openssh-server` und erhält keine sshd-Konfiguration. Verwaltung der PKI-VM erfolgt ausschließlich über die Hyper-V-Konsole.

### 5.8 – Funktionsnachweis

Von mintclient über Bastion zu Zielsystemen:

```bash
ssh -J student@bastion.gfn.internal student@monitoring.gfn.internal 'hostname'
ssh -J student@bastion.gfn.internal student@pcap.gfn.internal 'hostname'
ssh -J student@bastion.gfn.internal student@analysis.gfn.internal 'hostname'
# Erwartung: monitoring / pcap / analysis
```

Direktzugriff von mintclient muss fehlschlagen:

```bash
ssh student@monitoring.gfn.internal
ssh student@pcap.gfn.internal
ssh student@analysis.gfn.internal
# Erwartung: Permission denied (publickey)
```

---

## Schritt 6 – PKI: CA und Zertifikate auf der PKI-VM

### 6.1 – CA und Zertifikate erstellen

Alle Zertifikate werden ausschließlich auf der PKI-VM erstellt. Der CA-Private-Key verlässt die PKI-VM nicht.

Auf der PKI-VM:

```bash
mkdir -p ~/certs && cd ~/certs
```

Skripte herunterladen:

```bash
BASE_URL="https://raw.githubusercontent.com/dvrdnz/LF11Bv2/main/scripts/pki"

wget -q "${BASE_URL}/01-create-ca.sh"
wget -q "${BASE_URL}/02-issue-server-certs.sh"
wget -q "${BASE_URL}/03-issue-client-cert.sh"

chmod +x 0*.sh
```

Ausführen:

```bash
./01-create-ca.sh
./02-issue-server-certs.sh
./03-issue-client-cert.sh
```

Die Skripte im Überblick:

**`01-create-ca.sh`** – CA-Key und selbst-signiertes CA-Zertifikat erzeugen:

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

CA_KEY="ca.key"
CA_CRT="ca.crt"
CA_EXT="ca_ext.cnf"

openssl genrsa -out "$CA_KEY" 4096
chmod 600 "$CA_KEY"

cat > "$CA_EXT" <<'EOF'
[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req -x509 -new -nodes \
  -key "$CA_KEY" \
  -sha256 \
  -days 3650 \
  -subj "/CN=lab-ca" \
  -extensions v3_ca \
  -extfile "$CA_EXT" \
  -out "$CA_CRT"

rm -f "$CA_EXT"

echo "CA erstellt:"
echo "  - $CA_KEY"
echo "  - $CA_CRT"
```

**`02-issue-server-certs.sh`** – Server-Zertifikate für alle Hosts ausstellen:

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

CA_KEY="ca.key"
CA_CRT="ca.crt"
ISSUED_CSV="issued_certs.csv"

HOSTS=(monitoring pcap analysis mintclient pfsense bastion pki)

if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "Fehlt: $CA_KEY oder $CA_CRT" >&2
  exit 1
fi

if [[ ! -f "$ISSUED_CSV" ]]; then
  echo "name,expires" > "$ISSUED_CSV"
fi

for HOST in "${HOSTS[@]}"; do
  KEY="${HOST}.key"
  CSR="${HOST}.csr"
  CRT="${HOST}.crt"
  EXT="${HOST}_ext.cnf"

  openssl genrsa -out "$KEY" 2048

  openssl req -new \
    -key "$KEY" \
    -subj "/CN=${HOST}.gfn.internal" \
    -out "$CSR"

  cat > "$EXT" <<EOF
[ v3_srv ]
subjectAltName = DNS:${HOST}.gfn.internal
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

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

  END_DATE="$(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2)"
  echo "${HOST},${END_DATE}" >> "$ISSUED_CSV"

  rm -f "$CSR" "$EXT"

  echo "Ausgestellt: $CRT"
done

echo "Fertig. Übersicht: $ISSUED_CSV"
```

**`03-issue-client-cert.sh`** – Prometheus mTLS-Client-Zertifikat ausstellen:

```bash
#!/usr/bin/env bash
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

if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "Fehlt: $CA_KEY oder $CA_CRT" >&2
  exit 1
fi

openssl genrsa -out "$KEY" 2048

openssl req -new \
  -key "$KEY" \
  -subj "/CN=${CLIENT_CN}" \
  -out "$CSR"

cat > "$EXT" <<EOF
[ v3_client ]
subjectAltName = DNS:${CLIENT_CN}
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
EOF

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

rm -f "$CSR" "$EXT"

echo "Ausgestellt:"
echo "  - $KEY"
echo "  - $CRT"
```

Validierung:

```bash
openssl verify -CAfile ~/certs/ca.crt ~/certs/monitoring.crt
openssl verify -CAfile ~/certs/ca.crt ~/certs/prometheus-client.crt
openssl x509 -in ~/certs/monitoring.crt -text -noout | grep -A1 "Subject Alternative"
```

Erwartung: `monitoring.crt: OK`, `prometheus-client.crt: OK`, `DNS:monitoring.gfn.internal`

### 6.2 – PKI-VM als Trust-SSOT

Mit Abschluss von Schritt 6.1 ist die Vertrauensarchitektur dieser Umgebung festgelegt:

| Rolle | System | Zuständigkeit |
| --- | --- | --- |
| Netz-SSOT | pfSense | IP-Vergabe, DNS, NTP, Firewall |
| Trust-SSOT | PKI-VM | CA, Zertifikatsausstellung, Signierung |
| Verwaltungs-SSOT | Bastion | SSH-Schlüsselverwaltung, autorisierter Verwaltungspfad |

Die CA und ihr Private Key liegen ausschließlich auf der PKI-VM. Kein anderes System besitzt den CA-Private-Key. pfSense erhält ausschließlich ihr eigenes Zertifikat und das CA-Zertifikat zur Verifikation – keine Signing-Fähigkeit. Die MonitoringVM ist kein Teil der Vertrauenshierarchie: Sie konsumiert Zertifikate, stellt sie nicht aus.

---

## Schritt 7 – Zertifikate verteilen

Die Verteilung erfolgt in zwei Phasen: PKI-VM überträgt die Zertifikate zur Bastion, die Bastion verteilt sie an die Zielsysteme.

### 7.1 – Zertifikate von PKI-VM auf Bastion übertragen

Von der PKI-VM:

```bash
ssh student@bastion.gfn.internal 'mkdir -p ~/certs'

scp ~/certs/ca.crt \
    ~/certs/monitoring.crt ~/certs/monitoring.key \
    ~/certs/pcap.crt ~/certs/pcap.key \
    ~/certs/analysis.crt ~/certs/analysis.key \
    ~/certs/mintclient.crt ~/certs/mintclient.key \
    ~/certs/pfsense.crt ~/certs/pfsense.key \
    ~/certs/prometheus-client.crt ~/certs/prometheus-client.key \
    student@bastion.gfn.internal:~/certs/
```

> `ca.key` wird nicht übertragen. Der CA-Private-Key verbleibt ausschließlich auf der PKI-VM.

### 7.2 – Von Bastion auf Zielsysteme verteilen

Von der Bastion:

```bash
# pcap
scp ~/certs/ca.crt ~/certs/pcap.crt ~/certs/pcap.key \
    student@pcap.gfn.internal:~/

# analysis
scp ~/certs/ca.crt ~/certs/analysis.crt ~/certs/analysis.key \
    student@analysis.gfn.internal:~/
```

**Bootstrap-Schritt für `mintclient`:** `mintclient` benötigt für die Zertifikatsverteilung einmalig temporären SSH-Inbound von der Bastion. Dazu muss der Bastion-Key vorab auf `mintclient` hinterlegt werden – über RDP vom Windows-Host:

```bash
# Auf mintclient (via RDP):
mkdir -p ~/.ssh
echo "<inhalt von ~/id_ed25519.pub der Bastion>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Anschließend von der Bastion:

```bash
# mintclient
scp ~/certs/ca.crt ~/certs/mintclient.crt ~/certs/mintclient.key \
    student@mintclient.gfn.internal:~/
```

> Dieser SSH-Zugang ist ein reines Bootstrap-Verfahren. Nach Abschluss wird der Bastion-Key wieder aus `~/.ssh/authorized_keys` auf `mintclient` entfernt – siehe Bootstrap-Bereinigung am Ende dieses Schritts.

Auf jeder Ziel-VM (`pcap`, `analysis`, `mintclient`) einloggen und:

```bash
sudo mkdir -p /etc/observability/tls
sudo groupadd observability
sudo usermod -aG observability node_exporter
sudo mv ~/*.crt ~/*.key /etc/observability/tls/
sudo chown root:observability /etc/observability/tls/*.key
sudo chmod 640 /etc/observability/tls/*.key
sudo chown root:root /etc/observability/tls/*.crt
sudo chmod 644 /etc/observability/tls/*.crt
sudo chown root:observability /etc/observability/tls
sudo chmod 750 /etc/observability/tls
```

### 7.3 – TLS-Material auf MonitoringVM einrichten

Von der Bastion:

```bash
scp ~/certs/ca.crt \
    ~/certs/monitoring.crt ~/certs/monitoring.key \
    ~/certs/prometheus-client.crt ~/certs/prometheus-client.key \
    student@monitoring.gfn.internal:~/
```

Auf der MonitoringVM:

```bash
sudo mkdir -p /etc/observability/tls
sudo groupadd observability
sudo usermod -aG observability node_exporter
sudo usermod -aG observability prometheus

sudo mv ~/monitoring.crt ~/monitoring.key ~/ca.crt \
        ~/prometheus-client.crt ~/prometheus-client.key \
        /etc/observability/tls/

sudo chown root:observability /etc/observability/tls/monitoring.key \
  /etc/observability/tls/prometheus-client.key
sudo chmod 640 /etc/observability/tls/monitoring.key \
  /etc/observability/tls/prometheus-client.key
sudo chown root:root /etc/observability/tls/*.crt
sudo chmod 644 /etc/observability/tls/*.crt
sudo chown root:observability /etc/observability/tls
sudo chmod 750 /etc/observability/tls
```

Erwartetes Ergebnis auf der MonitoringVM:

```text
/etc/observability/tls/
├── ca.crt                    (root:root          644)
├── monitoring.crt            (root:root          644)
├── monitoring.key            (root:observability 640)
├── prometheus-client.crt     (root:root          644)
└── prometheus-client.key     (root:observability 640)
```

**Bootstrap-Bereinigung für `mintclient`:** Der temporäre SSH-Inbound von der Bastion wird jetzt entfernt. Auf `mintclient` (via RDP):

```bash
nano ~/.ssh/authorized_keys
# Bastion-Zeile löschen
```

Funktionsnachweis – Direktzugriff von der Bastion muss fehlschlagen:

```bash
# Von der Bastion:
ssh student@mintclient.gfn.internal
# Erwartung: Permission denied (publickey)
```

Nach erfolgreicher Verteilung kann die PKI-VM heruntergefahren werden. Sie wird erst wieder benötigt, wenn Zertifikate erneuert werden müssen.

```bash
sudo shutdown -h now
```

---

## Schritt 8 – Node Exporter auf Linux-VMs mit mTLS konfigurieren

Für jede VM (`monitoring .20`, `pcap .21`, `analysis .22`, `mintclient .10`) – Hostname in `web.yml` jeweils anpassen.

```bash
sudo nano /etc/node_exporter/web.yml
```

```yaml
tls_server_config:
  cert_file: /etc/observability/tls/<HOST>.crt
  key_file: /etc/observability/tls/<HOST>.key
  client_ca_file: /etc/observability/tls/ca.crt
  client_auth_type: RequireAndVerifyClientCert
  client_allowed_sans:
    - prometheus.gfn.internal
```

> `client_allowed_sans` stellt sicher, dass ausschließlich Prometheus mit seinem dedizierten Client-Zertifikat akzeptiert wird. Jeder andere Client – auch mit gültigem CA-signierten Zertifikat – wird abgewiesen.

```bash
sudo systemctl restart node_exporter
sudo systemctl status node_exporter
```

Validierung von der Bastion (über SSH auf MonitoringVM):

```bash
sudo curl --cacert /etc/observability/tls/ca.crt \
     --cert /etc/observability/tls/prometheus-client.crt \
     --key /etc/observability/tls/prometheus-client.key \
     https://<HOST>.gfn.internal:9100/metrics
# Erwartung: Metriken werden zurückgegeben

sudo curl --cacert /etc/observability/tls/ca.crt \
     https://<HOST>.gfn.internal:9100/metrics
# Erwartung: TLS-Handshake wird abgewiesen
```

**Sonderfall `analysis` – Blackbox Exporter:**

```bash
sudo nano /etc/blackbox_exporter/web.yml
```

```yaml
tls_server_config:
  cert_file: /etc/observability/tls/analysis.crt
  key_file: /etc/observability/tls/analysis.key
  client_ca_file: /etc/observability/tls/ca.crt
  client_auth_type: RequireAndVerifyClientCert
  client_allowed_sans:
    - prometheus.gfn.internal
```

```bash
sudo chown node_exporter:node_exporter /etc/blackbox_exporter/web.yml
sudo systemctl restart blackbox_exporter
sudo systemctl status blackbox_exporter
```

---

## Schritt 9 – TLS für pfSense Node Exporter via HAProxy

Das `node_exporter`-Package auf pfSense unterstützt kein TLS nativ. HAProxy übernimmt die TLS-Terminierung: Es lauscht auf Port `9101` (HTTPS) und leitet intern an `192.168.10.2:9100` (HTTP) weiter.

> pfSense erhält ausschließlich ihr eigenes Zertifikat und das CA-Zertifikat zur Verifikation – kein CA-Private-Key. pfSense kann damit TLS-Verbindungen terminieren, aber keine neuen Identitäten ausstellen.

Die Zertifikatsinhalte für den Import werden von der Bastion abgerufen:

```bash
ssh student@bastion.gfn.internal 'cat ~/certs/ca.crt'
ssh student@bastion.gfn.internal 'cat ~/certs/pfsense.crt'
ssh student@bastion.gfn.internal 'cat ~/certs/pfsense.key'
```

#### CA-Zertifikat in pfSense importieren

**System → Certificates → Authorities → Add**

| Feld | Wert |
| --- | --- |
| Descriptive name | `lab-ca` |
| Method | `Import an existing Certificate Authority` |
| Certificate data | Inhalt von `ca.crt` |
| Certificate Private Key | leer lassen |
| Trust Store | aktivieren |

→ **Save**

#### pfSense-Zertifikat importieren

**System → Certificates → Certificates → Add**

| Feld | Wert |
| --- | --- |
| Method | `Import an existing Certificate` |
| Descriptive name | `pfsense` |
| Certificate data | Inhalt von `pfsense.crt` |
| Private key data | Inhalt von `pfsense.key` |

→ **Save**

#### HAProxy installieren

**System → Package Manager → Available Packages → haproxy → Install**

#### HAProxy Settings

**Services → HAProxy → Settings**

| Feld | Wert |
| --- | --- |
| Enable HAProxy | aktiv |
| Maximum connections | `1000` |

→ **Save**

#### HAProxy Backend

**Services → HAProxy → Backend → Add**

| Feld | Wert |
| --- | --- |
| Name | `node_exporter_backend` |

Server list → Add:

| Feld | Wert |
| --- | --- |
| Mode | `active` |
| Name | `node_exporter` |
| Address | `192.168.10.2` |
| Port | `9100` |
| Encrypt(SSL) | deaktiviert |
| Health check | None |

→ **Save**

#### HAProxy Frontend

**Services → HAProxy → Frontend → Add**

| Feld | Wert |
| --- | --- |
| Name | `node_exporter_tls` |
| Status | `Active` |
| External address | `192.168.10.2`, Port `9101`, SSL Offloading aktiviert |
| Type | `http / https(offloading)` |
| Certificate | `pfsense (CA: lab-ca)` |
| Add ACL for certificate Subject Alternative Names | deaktiviert |
| Default backend | `node_exporter_backend` |

> Das ACL für Subject Alternative Names muss deaktiviert sein – sonst generiert pfSense eine ACL, die auf den internen pfSense-Hostnamen matched und alle anderen Verbindungen verwirft.

→ **Save** → **Apply Changes**

#### Firewall-Regel für Port 9101

**Firewall → Rules → LAN → Add**

| Feld | Wert |
| --- | --- |
| Action | Pass |
| Protocol | TCP |
| Source | `192.168.10.20` |
| Destination | `192.168.10.2` |
| Destination Port | `9101` |
| Description | `Allow Prometheus scrape pfSense node_exporter TLS` |

→ **Save** → **Apply Changes**

Validierung von der MonitoringVM:

```bash
sudo curl --cacert /etc/observability/tls/ca.crt \
     --cert /etc/observability/tls/prometheus-client.crt \
     --key /etc/observability/tls/prometheus-client.key \
     https://pfsense.gfn.internal:9101/metrics
```

Erwartung: Metriken werden zurückgegeben.

---

## Schritt 10 – Prometheus-UI mit TLS absichern

Prometheus läuft als User `prometheus`. Zertifikate nach `/etc/prometheus/` kopieren:

```bash
sudo cp /etc/observability/tls/monitoring.crt /etc/prometheus/
sudo cp /etc/observability/tls/monitoring.key /etc/prometheus/
sudo cp /etc/observability/tls/ca.crt /etc/prometheus/
sudo cp /etc/observability/tls/prometheus-client.crt /etc/prometheus/
sudo cp /etc/observability/tls/prometheus-client.key /etc/prometheus/
sudo chown prometheus:prometheus \
  /etc/prometheus/monitoring.crt \
  /etc/prometheus/monitoring.key \
  /etc/prometheus/ca.crt \
  /etc/prometheus/prometheus-client.crt \
  /etc/prometheus/prometheus-client.key
sudo chmod 644 /etc/prometheus/monitoring.crt \
  /etc/prometheus/ca.crt \
  /etc/prometheus/prometheus-client.crt
sudo chmod 640 /etc/prometheus/monitoring.key \
  /etc/prometheus/prometheus-client.key
```

`web.yml` anlegen:

```bash
sudo nano /etc/prometheus/web.yml
```

```yaml
tls_server_config:
  cert_file: /etc/prometheus/monitoring.crt
  key_file: /etc/prometheus/monitoring.key
```

Systemd-Unit anpassen:

```bash
sudo nano /etc/systemd/system/prometheus.service
```

```ini
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.config.file=/etc/prometheus/web.yml

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart prometheus
sudo systemctl status prometheus
```

Validierung:

```bash
sudo curl --cacert /etc/observability/tls/ca.crt \
     https://monitoring.gfn.internal:9090/metrics
```

Erwartung: Metriken werden zurückgegeben. Das Prometheus-UI ist ab jetzt ausschließlich über `https://monitoring.gfn.internal:9090` erreichbar.

---

## Schritt 11 – Prometheus: IPs durch Hostnamen ersetzen und mTLS aktivieren

Prometheus löst Hostnamen zur Scrape-Zeit auf – über pfSense als konfigurierten DNS-Resolver. Mit Hostnamen in `prometheus.yml` delegiert Prometheus die Adressauflösung vollständig an pfSense.

```bash
sudo nano /etc/prometheus/prometheus.yml
```

```yaml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: 'nodes'
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      cert_file: /etc/prometheus/prometheus-client.crt
      key_file: /etc/prometheus/prometheus-client.key
    static_configs:
      - targets:
        - pfsense.gfn.internal:9101
        - mintclient.gfn.internal:9100
        - monitoring.gfn.internal:9100
        - pcap.gfn.internal:9100
        - analysis.gfn.internal:9100

  - job_name: 'windows'
    static_configs:
      - targets:
        - 10.10.10.1:9182              # Windows Host – kein TLS (isolierter vSwitch, außerhalb LAN)

  - job_name: 'blackbox'
    metrics_path: /probe
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      cert_file: /etc/prometheus/prometheus-client.crt
      key_file: /etc/prometheus/prometheus-client.key
    params:
      module: [icmp_check]
    static_configs:
      - targets:
        - pfsense.gfn.internal
        - monitoring.gfn.internal
        - pcap.gfn.internal
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: analysis.gfn.internal:9115

  - job_name: 'blackbox_dns'
    metrics_path: /probe
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      cert_file: /etc/prometheus/prometheus-client.crt
      key_file: /etc/prometheus/prometheus-client.key
    params:
      module: [dns_check]
    static_configs:
      - targets:
        - pfsense.gfn.internal
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: analysis.gfn.internal:9115
```

```bash
sudo systemctl restart prometheus
```

Funktionsnachweis: `https://monitoring.gfn.internal:9090/targets` → alle Targets `State: UP`, Hostnamen und HTTPS-Schema in der Endpoint-Spalte sichtbar.

---

## Schritt 12 – Firewall: strukturelles Hardening

### Ausgangslage

Die HTTP/HTTPS-Regel wurde in `01-firewall.md` bewusst breit gefasst. In den Kapiteln 07–09 wurde jede VM nach ihrer Installation per Block-Regel vom Internet getrennt:

| Action | Source | Destination | Port | Herkunft |
| --- | --- | --- | --- | --- |
| Pass | LAN subnets | any | 80/443 | `01-firewall.md` |
| Block | 192.168.10.20 | !192.168.10.0/24 | any | `07-monitoring.md` |
| Block | 192.168.10.21 | !192.168.10.0/24 | any | `08-capture.md` |
| Block | 192.168.10.22 | !192.168.10.0/24 | any | `09-analysis.md` |

Alle Observability-VMs sind installiert. Bastion und PKI-VM benötigen ebenfalls keinen Internet-Zugang. Die HTTP/HTTPS-Regel wird auf mintclient eingeschränkt, die redundanten Block-Regeln werden entfernt.

### 12.1 – HTTP/HTTPS-Regel einschränken

**Firewall → Rules → LAN → HTTP_HTTPS-Regel bearbeiten**

| Feld | Alt | Neu |
| --- | --- | --- |
| Source Type | `LAN subnets` | `Address or Alias` |
| Source Address | – | `192.168.10.10` |
| Description | `Allow HTTP/HTTPS LAN` | `Allow HTTP/HTTPS – admin client only` |

→ **Save** (noch nicht Apply)

> `192.168.10.10` ist `mintclient` – der einzige Host im Netz, der legitimen Internet-Zugriff über HTTP/HTTPS benötigt.

### 12.2 – Redundante Block-Regeln entfernen

Mit der geänderten Grundregel hat kein Host außer `192.168.10.10` eine Pass-Regel für HTTP/HTTPS. Das implizite Deny greift. Die drei Block-Regeln für `.20`, `.21`, `.22` haben damit keine eigenständige Funktion mehr. Bastion und PKI-VM benötigen ebenfalls keine eigenen Block-Regeln – sie sind durch die eingeschränkte Grundregel bereits implizit ausgeschlossen.

**Firewall → Rules → LAN → alle drei Block-to-Internet-Regeln markieren → Delete**

→ **Apply Changes**

### 12.3 – DHCP-Pool einschränken

**Services → DHCP Server → LAN**

| Feld | Alt | Neu |
| --- | --- | --- |
| Range From | `192.168.10.100` | `192.168.10.200` |
| Range To | `192.168.10.245` | `192.168.10.210` |

→ **Save**

> Der Bereich `.200–.210` (11 Adressen) ist ausreichend für temporäre Geräte oder neue VMs während der Ersteinrichtung. Alle bekannten Hosts liegen per Static Mapping unterhalb von `.100`. Bastion (.99) und PKI-VM (.199) liegen außerhalb des dynamischen Pools – eine Überschneidung ist ausgeschlossen.

### 12.4 – Architekturbedingte Grenze

pfSense filtert ausschließlich Traffic, der durch sie hindurchläuft (Layer 3). LAN-zu-LAN-Traffic zwischen Hosts im selben Subnetz wird direkt über den Switch (Layer 2) vermittelt – pfSense ist nicht im Pfad. Die CaptureVM (pcap) sitzt zwar als Bridge auf Layer 2, sieht den Traffic jedoch nur dann, wenn dieser tatsächlich über ihre Interfaces geführt wird. Erfolgt die Kommunikation direkt über den virtuellen Switch, ohne die Bridge zu durchlaufen, bleibt der Traffic für pcap unsichtbar. Eine echte Zugriffskontrolle zwischen VMs ist nur über Netzsegmentierung (z.B. VLANs) möglich. `AllowUsers` in sshd schließt diese Lücke auf Anwendungsebene für SSH; mTLS schließt sie für Prometheus-Scraping: Auch wenn pfSense den Traffic nicht filtert, akzeptieren die Exporter ausschließlich Prometheus als authentifizierten Client.

---

## Ergebnis & Ausblick

Nach diesem Kapitel ist die Observability-Schicht nicht nur funktionsfähig, sondern strukturell konsistent. Die Verantwortlichkeiten sind klar getrennt und auf dedizierte Systeme verteilt:

* **DNS** ist die verbindliche Namensschicht – alle Systeme werden über pfSense aufgelöst
* **SSH** folgt einem eindeutig definierten Verwaltungspfad über die Bastion
* **Zertifikate** werden ausschließlich von der PKI-VM ausgestellt; der CA-Key verlässt sie nicht
* **mTLS** stellt die Authentizität der Metriken sicher
* **Prometheus** arbeitet mit Hostnamen und verifizierten Identitäten
* **Firewall und DHCP** entsprechen dem finalen Betriebszustand

Damit entsteht eine geschlossene Architektur aus klar voneinander getrennten Rollen:

| Rolle | System | Zuständigkeit |
| --- | --- | --- |
| Netz-SSOT | pfSense | IP-Vergabe, DNS Resolver, NTP, Firewall, DNS Host Overrides |
| Trust-SSOT | PKI-VM | Offline-CA, Signierung und Ausstellung aller TLS-Zertifikate |
| Verwaltungs-SSOT | BastionVM | einziger autorisierter SSH-Jump-Host, kontrollierter Admin-Zugriff auf Zielsysteme |
| Observability-Frontend | MonitoringVM | Prometheus, Grafana, zentrale Auswertung und Visualisierung |
| Wire-Level-Komponente | CaptureVM | transparente Bridge und Paketmitschnitt auf Layer 2 |
| Aktiver Messpunkt | AnalysisVM | blackbox_exporter, NTP-/DNS-/ICMP-Messungen |
| Admin-Desktop | mintclient | RDP-Entrypoint, manuelle Bedienung, Startpunkt für administrative SSH-Verbindungen |
| | | als Admin-Client ohne eigene administrative Rolle innerhalb der Observability-Domäne |

Ohne TLS vertraut Prometheus blind jeder Antwort im Netzwerk. Ein kompromittierter Host kann beliebige Metriken liefern und damit Monitoring und Alerts gezielt manipulieren. TLS stellt sicher, dass ausschließlich verifizierte Targets akzeptiert werden.

Jede Entscheidung dieses Kapitels folgt demselben Prinzip: Vertrauen wird nicht vorausgesetzt, sondern erzwungen. DNS löst auf, weil pfSense es vorgibt. SSH erreicht Zielsysteme, weil die Bastion es erlaubt. Metriken werden akzeptiert, weil Zertifikate sie belegen.

Was in den Kapiteln 07–09 als Werkzeuge aufgebaut wurde, ist damit zu einer Infrastruktur mit definierten Vertrauensbeziehungen geworden – einer Schicht, die nicht nur beobachtet, sondern belastbare Aussagen liefert.

Im nächsten Kapitel wird diese Basis genutzt, um Metriken nicht nur zu erfassen, sondern gezielt für Entscheidung und Validierung einzusetzen.