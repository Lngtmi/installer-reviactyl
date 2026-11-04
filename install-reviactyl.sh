#!/usr/bin/env bash
# Reviactyl installer for Ubuntu 22.04 / 24.04 or Debian 12 (versi GitHub).
# Jaringan terdeteksi otomatis: IPv4 publik -> mode Direct (HTTPS langsung,
# A record panel + node wajib dibuat lebih dulu), NAT -> Cloudflare Tunnel.
# Run as root: bash install-reviactyl.sh install

set -Eeuo pipefail
trap 'rc=$?; echo "[INSTALL_ERROR] exit=$rc line=$LINENO command=$BASH_COMMAND" >&2; exit "$rc"' ERR
trap 'echo "[INSTALL_CANCELLED] Dibatalkan via sinyal TERM/INT (mis. /cancel dari bot). VPS mungkin dalam keadaan setengah terinstall; periksa sebelum menjalankan ulang." >&2; exit 130' TERM INT

PANEL_DIR=/var/www/reviactyl
NGINX_FILE=/etc/nginx/sites-available/reviactyl
STATE_FILE=/root/reviactyl-installer.env
REVIA_CF_CONFIG=/etc/cloudflared/reviactyl.yml
REVIA_CF_SERVICE=cloudflared-reviactyl
DIRECT_MODE_PRESET=0
[[ -n ${DIRECT_MODE:-} ]] && DIRECT_MODE_PRESET=1
DIRECT_MODE=${DIRECT_MODE:-0}
PUBLIC_IP=${PUBLIC_IP:-}

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-999} -eq 0 ]] || die "Jalankan sebagai root (sudo -i)."; }
check_public_dns() {
  # DNS Cloudflare kadang baru terlihat beberapa saat setelah route dibuat.
  # Ini hanya informasi; panel lokal tidak boleh dianggap gagal karena propagasi.
  local host resolved
  for host in "$@"; do
    resolved=0
    for _ in {1..12}; do
      if getent ahosts "$host" >/dev/null 2>&1; then resolved=1; break; fi
      sleep 5
    done
    if (( resolved )); then
      echo "[DNS_OK] $host sudah ter-resolve publik."
    else
      echo "[DNS_PENDING] $host belum ter-resolve publik. Tunggu propagasi DNS; bila tetap NXDOMAIN jalankan /perbaiki_domain dari bot."
    fi
  done
}
wait_for_apt() {
  # VPS baru dapat menjalankan update otomatis selama beberapa menit.
  # Tunggu lock selesai; jangan hentikan pembaruan sistem secara paksa.
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    (( waited >= 600 )) && die "Lock apt/dpkg masih dipakai setelah 10 menit. Tunggu update VPS selesai lalu jalankan ulang."
    echo "[WAIT_APT_LOCK] Menunggu update sistem selesai (${waited} detik)..."
    sleep 5
    ((waited+=5))
  done
}

detect_ip_mode() {
  # Logika yang sama dengan bot: bandingkan IP egress publik VPS dengan
  # daftar IP yang benar-benar terpasang di interface. Sama = IPv4 publik
  # (direct), beda = di belakang NAT (tunnel), tidak jelas = unknown.
  local svc egress iface
  DETECT_RESULT=unknown
  PUBLIC_IP=""
  for svc in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    egress=$(curl -4 -fsS --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ $egress =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then PUBLIC_IP=$egress; break; fi
  done
  [[ -n $PUBLIC_IP ]] || return 0
  iface=$( { ip -4 addr show scope global 2>/dev/null | awk '{print $2}' | cut -d/ -f1; hostname -I 2>/dev/null | tr ' ' '\n'; } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)
  [[ -n $iface ]] || return 0
  if grep -qx "$PUBLIC_IP" <<<"$iface"; then DETECT_RESULT=public; else DETECT_RESULT=nat; fi
}

choose_network_mode() {
  # Khusus jalur interaktif (pemakaian langsung dari GitHub). Bila mode sudah
  # ditentukan pemanggil lewat env (mis. bot), hormati dan jangan menebak.
  if [[ ${AUTO_MODE:-0} == 1 || $DIRECT_MODE_PRESET == 1 ]]; then
    if [[ $DIRECT_MODE == 1 ]]; then echo "[MODE] Mode DIRECT (ditentukan pemanggil)."; else echo "[MODE] Mode TUNNEL (ditentukan pemanggil)."; fi
    return
  fi
  echo "Mendeteksi jaringan VPS..."
  detect_ip_mode
  case "$DETECT_RESULT" in
    public)
      DIRECT_MODE=1
      echo "[MODE] Terdeteksi IPv4 publik $PUBLIC_IP di VPS ini -> mode DIRECT (HTTPS langsung, tanpa tunnel)."
      ;;
    nat)
      DIRECT_MODE=0
      echo "[MODE] VPS berada di belakang NAT (IP publik $PUBLIC_IP tidak terpasang di interface) -> mode TUNNEL Cloudflare."
      ;;
    *)
      echo "[MODE] Jenis jaringan VPS tidak dapat dipastikan otomatis."
      local choice
      read -r -p "Pilih mode: [1] Direct - VPS punya IPv4 publik  [2] Tunnel - VPS di belakang NAT [2]: " choice || choice=2
      if [[ $choice == 1 ]]; then
        DIRECT_MODE=1
        if [[ -z $PUBLIC_IP ]]; then
          read -r -p "IP publik VPS ini: " PUBLIC_IP || PUBLIC_IP=""
          [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Format IP publik tidak valid."
        fi
        echo "[MODE] Mode DIRECT dipilih manual (IP publik: $PUBLIC_IP)."
      else
        DIRECT_MODE=0
        echo "[MODE] Mode TUNNEL dipilih manual."
      fi
      ;;
  esac
}

resolve_public_ips() {
  # Tanya resolver PUBLIK langsung lewat DNS-over-HTTPS, bukan resolver lokal
  # VPS: cache negatif resolver lokal bisa tetap menjawab "tidak ada" selama
  # beberapa menit untuk record yang sebenarnya sudah benar (kejadian live
  # 2026-11-04: bebeb.everything.my.id sudah live di Cloudflare tetapi getent
  # di VPS masih buta). Let's Encrypt juga menilai dari sisi publik, jadi
  # inilah standar yang benar untuk gate. Urutan: Cloudflare DoH -> Google
  # DoH -> getent lokal sebagai cadangan terakhir.
  local host=$1 out=""
  if command -v curl >/dev/null 2>&1; then
    out=$(curl -fsS --max-time 8 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${host}&type=A" 2>/dev/null | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u || true)
    if [[ -z $out ]]; then
      out=$(curl -fsS --max-time 8 "https://dns.google/resolve?name=${host}&type=A" 2>/dev/null | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u || true)
    fi
  fi
  if [[ -z $out ]]; then
    out=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)
  fi
  printf '%s' "$out"
}

dns_gate_direct() {
  # Mode direct menerbitkan sertifikat lewat certbot, jadi A record panel +
  # node HARUS sudah mengarah ke IP VPS ini sebelum instalasi berjalan.
  # Installer versi GitHub tidak membuatkan record (tidak ada token DNS
  # pemakai), jadi catatannya ditampilkan di awal dan hasilnya diperiksa
  # sendiri di sini — tidak ada lagi kegagalan NXDOMAIN di tengah instalasi.
  [[ $DIRECT_MODE == 1 && ${AUTO_MODE:-0} != 1 ]] || return 0
  echo
  echo "================================================================"
  echo "  CATATAN PENTING - MODE DIRECT (IPv4 PUBLIK: $PUBLIC_IP)"
  echo "================================================================"
  echo "  Buat DULU 2 A record berikut di panel DNS domain $DOMAIN"
  echo "  (bila memakai Cloudflare, pilih 'DNS only' / awan abu-abu):"
  echo
  echo "    A    $PANEL_FQDN    ->    $PUBLIC_IP"
  echo "    A    $NODE_FQDN     ->    $PUBLIC_IP"
  echo
  echo "  Tanpa record ini, penerbitan sertifikat HTTPS akan GAGAL"
  echo "  dan instalasi berhenti di tengah. Record yang baru dibuat"
  echo "  biasanya aktif dalam 1-5 menit."
  echo "================================================================"
  local host ips ok all_ok ans
  while true; do
    all_ok=1
    for host in "$PANEL_FQDN" "$NODE_FQDN"; do
      ips=$(resolve_public_ips "$host")
      ok=0
      if grep -qx "$PUBLIC_IP" <<<"$ips"; then ok=1; fi
      if (( ok )); then
        echo "[DNS_OK] $host sudah mengarah ke $PUBLIC_IP."
      else
        all_ok=0
        if [[ -n $ips ]]; then
          echo "[DNS_BELUM] $host saat ini mengarah ke: $(echo $ips) (seharusnya $PUBLIC_IP)."
        else
          echo "[DNS_BELUM] $host belum ter-resolve sama sekali."
        fi
      fi
    done
    if (( all_ok )); then echo "[DNS_OK] Kedua subdomain sudah benar. Instalasi dilanjutkan."; return 0; fi
    read -r -p "Tekan Enter untuk memeriksa lagi, atau ketik 'batal' untuk berhenti: " ans || die "Dibatalkan. Buat dulu A record di atas, lalu jalankan ulang installer."
    if [[ ${ans,,} == batal ]]; then die "Dibatalkan. Buat dulu A record di atas, lalu jalankan ulang installer."; fi
  done
}

ask_network() {
  if [[ ${AUTO_MODE:-0} == 1 ]]; then
    : "${DOMAIN:?DOMAIN wajib diisi}"
    PANEL_SUB=${PANEL_SUB:-panel}
    NODE_SUB=${NODE_SUB:-node}
    AGENT_PORT=${AGENT_PORT:-443}
    [[ $DOMAIN =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Format domain tidak valid."
    [[ $AGENT_PORT =~ ^[0-9]+$ ]] || die "Port harus angka."
    PANEL_FQDN="${PANEL_SUB}.${DOMAIN}"
    NODE_FQDN="${NODE_SUB}.${DOMAIN}"
    return
  fi
  read -r -p "Domain utama (contoh: domainkamu.com): " DOMAIN
  [[ $DOMAIN =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Format domain tidak valid."
  read -r -p "Subdomain panel [panel]: " PANEL_SUB
  read -r -p "Subdomain node [node]: " NODE_SUB
  if [[ $DIRECT_MODE == 1 ]]; then
    read -r -p "Port Agent [8080]: " AGENT_PORT
    AGENT_PORT=${AGENT_PORT:-8080}
  else
    read -r -p "Port Agent lokal untuk Cloudflare Tunnel [443]: " AGENT_PORT
    AGENT_PORT=${AGENT_PORT:-443}
  fi
  PANEL_SUB=${PANEL_SUB:-panel}
  NODE_SUB=${NODE_SUB:-node}
  [[ $AGENT_PORT =~ ^[0-9]+$ ]] || die "Port harus angka."
  PANEL_FQDN="${PANEL_SUB}.${DOMAIN}"
  NODE_FQDN="${NODE_SUB}.${DOMAIN}"
}

save_state() {
  umask 077
  cat >"$STATE_FILE" <<EOF
DOMAIN='$DOMAIN'
PANEL_SUB='$PANEL_SUB'
NODE_SUB='$NODE_SUB'
PANEL_FQDN='$PANEL_FQDN'
NODE_FQDN='$NODE_FQDN'
AGENT_PORT='$AGENT_PORT'
TUNNEL_NAME='$TUNNEL_NAME'
TUNNEL_ID='$TUNNEL_ID'
EOF
}

write_tunnel_config() {
  mkdir -p /etc/cloudflared
  cat >"$REVIA_CF_CONFIG" <<EOF
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $PANEL_FQDN
    service: http://127.0.0.1:80
  - hostname: $NODE_FQDN
    service: http://127.0.0.1:$AGENT_PORT
  - service: http_status:404
EOF
}

write_nginx_config() {
  cat >"$NGINX_FILE" <<EOF
server {
    listen 80;
    server_name $PANEL_FQDN;
    root $PANEL_DIR/public;
    index index.php;
    client_max_body_size 100m;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \\.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
$(if [[ $DIRECT_MODE == 1 ]]; then cat <<'DIRECT'
        # HTTPS diterminasi langsung oleh Nginx/Let's Encrypt.
        fastcgi_param HTTPS on;
DIRECT
else cat <<'TUNNEL'
        # Cloudflare Tunnel terminates HTTPS before reaching Nginx.
        fastcgi_param HTTPS on;
        fastcgi_param HTTP_X_FORWARDED_PROTO https;
        fastcgi_param HTTP_X_FORWARDED_HOST $host;
        fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
TUNNEL
fi)
        fastcgi_read_timeout 300;
    }
    location ~ /\\. { deny all; }
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sfn "$NGINX_FILE" /etc/nginx/sites-enabled/reviactyl
}

install_panel() {
  need_root
  choose_network_mode
  ask_network
  dns_gate_direct
  echo
  echo "Panel : https://$PANEL_FQDN"
  echo "Node  : https://$NODE_FQDN (port Agent: $AGENT_PORT)"
  echo ""
  echo "PERINGATAN: mode ini menghapus Pterodactyl/Reviactyl lama, konfigurasi Wings/Agent,"
  echo "database MySQL bernama 'panel', serta Tunnel Reviactyl lama. Tunnel layanan lain tidak disentuh."
  if [[ ${AUTO_MODE:-0} == 1 ]]; then CONFIRM=HAPUS; else read -r -p "Ketik HAPUS untuk lanjut: " CONFIRM; fi
  [[ $CONFIRM == HAPUS ]] || die "Dibatalkan."

  source /etc/os-release
  [[ ( ${ID:-} == ubuntu && ( ${VERSION_ID:-} == 22.04 || ${VERSION_ID:-} == 24.04 ) ) || ( ${ID:-} == debian && ${VERSION_ID:-} == 12 ) ]] || die "Skrip ini mendukung Ubuntu 22.04/24.04 atau Debian 12. OS Anda: ${PRETTY_NAME:-tidak diketahui}."

  old_tunnel=""
  [[ -f $STATE_FILE ]] && old_tunnel=$(awk -F= '$1 == "TUNNEL_ID" {gsub(/\047/, "", $2); print $2; exit}' "$STATE_FILE" 2>/dev/null || true)
  systemctl disable --now wings agent pteroq reviq "$REVIA_CF_SERVICE" 2>/dev/null || true
  rm -rf /var/www/pterodactyl "$PANEL_DIR" /etc/pterodactyl /etc/reviactyl /var/lib/pterodactyl /var/lib/reviactyl
  rm -f "$REVIA_CF_CONFIG" "/etc/systemd/system/$REVIA_CF_SERVICE.service" "/root/.cloudflared/$old_tunnel.json"
  rm -f /usr/local/bin/wings /usr/local/bin/agent
  rm -f /etc/systemd/system/wings.service /etc/systemd/system/agent.service /etc/systemd/system/reviq.service
  rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-enabled/reviactyl /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-available/reviactyl /etc/cron.d/reviactyl
  docker network rm pterodactyl_nw 2>/dev/null || true
  mariadb -e "DROP DATABASE IF EXISTS panel; DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1'; DROP USER IF EXISTS 'pterodactyl'@'localhost'; DROP USER IF EXISTS 'reviactyl'@'127.0.0.1'; DROP USER IF EXISTS 'reviactyl'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
  systemctl daemon-reload

  # Ubuntu 22.04 dan Debian 12 belum menyediakan PHP 8.3 secara bawaan,
  # sedangkan Reviactyl memerlukannya. Gunakan repositori PHP yang sesuai
  # untuk masing-masing distribusi.
  if [[ ${VERSION_ID:-} == 22.04 ]]; then
    wait_for_apt
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y software-properties-common apt-transport-https
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  elif [[ ${ID:-} == debian ]]; then
    wait_for_apt
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl gnupg lsb-release
    install -d -m 0755 /etc/apt/keyrings
    # --batch/--yes penting karena instalasi dipanggil oleh bot tanpa TTY dan
    # file key bisa sudah ada dari percobaan instalasi sebelumnya.
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/sury-php.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" >/etc/apt/sources.list.d/sury-php.list
  fi
  wait_for_apt
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget nano ca-certificates gnupg lsb-release \
    nginx mariadb-server redis-server tar unzip git jq openssl certbot python3-certbot-nginx \
    php8.3 php8.3-{cli,common,gd,mbstring,bcmath,xml,fpm,curl,zip,intl,redis,sqlite3,mysql}
  curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

  DB_PASSWORD=$(openssl rand -hex 24)
  mariadb <<SQL
DROP DATABASE IF EXISTS panel;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
DROP USER IF EXISTS 'pterodactyl'@'localhost';
CREATE DATABASE panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"
  curl -fL -o panel.tar.gz https://github.com/reviactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzf panel.tar.gz
  rm panel.tar.gz
  cp .env.example .env
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  php artisan key:generate --force

  if [[ ${AUTO_MODE:-0} == 1 ]]; then
    : "${ADMIN_USER:?ADMIN_USER wajib diisi}"
    : "${ADMIN_PASS:?ADMIN_PASS wajib diisi}"
    set_env() { local key=$1 value=$2; if grep -q "^${key}=" .env; then sed -i "s|^${key}=.*|${key}=${value}|" .env; else echo "${key}=${value}" >>.env; fi; }
    set_env APP_URL "https://$PANEL_FQDN"
    set_env APP_TIMEZONE "Asia/Jakarta"
    set_env CACHE_STORE redis
    set_env SESSION_DRIVER redis
    set_env QUEUE_CONNECTION redis
    set_env REDIS_HOST 127.0.0.1
    set_env REDIS_PORT 6379
    set_env DB_CONNECTION mysql
    set_env DB_HOST 127.0.0.1
    set_env DB_PORT 3306
    set_env DB_DATABASE panel
    set_env DB_USERNAME pterodactyl
    set_env DB_PASSWORD "$DB_PASSWORD"
    set_env MAIL_MAILER log
    set_env MAIL_FROM_ADDRESS "${ADMIN_USER}@${DOMAIN}"
    set_env MAIL_FROM_NAME Reviactyl
    echo "[AUTO] Konfigurasi aplikasi dan database selesai."
  else
    echo
    echo "PANDUAN MENGISI WIZARD (ikuti urutannya):"
    echo "  [Setup]  Egg Author Email : email kamu sendiri"
    echo "  [Setup]  Application URL  : https://$PANEL_FQDN"
    echo "  [Setup]  Timezone         : Asia/Jakarta"
    echo "  [Setup]  Cache Driver     : redis"
    echo "  [Setup]  Session Driver   : redis"
    echo "  [Setup]  Queue Driver     : redis"
    echo "  [Setup]  UI settings editor : yes"
    echo "  [Setup]  Telemetry        : no"
    echo "  [Setup]  Redis Host/Password/Port : Enter saja (bawaan)"
    echo "  [DB]     Database Driver  : mariadb   <-- JANGAN Enter! Bawaan SQLite akan GAGAL."
    echo "  [DB]     Database host    : 127.0.0.1 (Enter)"
    echo "  [DB]     Database port    : 3306 (Enter)"
    echo "  [DB]     Database name    : panel"
    echo "  [DB]     Database user    : pterodactyl"
    echo "  [DB]     Database pass    : $DB_PASSWORD"
    echo "  [Mail]   Mail Driver      : log"
    echo "  [Mail]   Mail From Address: no-reply@$DOMAIN"
    echo "  [Mail]   Mail From Name   : Reviactyl"
    echo "  Setelah wizard: buat akun admin panel (email/username/password bebas, min. 8 karakter)."
    read -r -p "Tekan Enter untuk membuka wizard..." _
    php artisan p:environment:setup
    php artisan p:environment:database
    php artisan p:environment:mail
  fi
  grep -q '^TRUSTED_PROXIES=' .env && sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|' .env || echo 'TRUSTED_PROXIES=*' >>.env
  # Designify only accepts changes saved from its UI when this is false. Keep
  # environment-only mode disabled so the administrator can edit branding,
  # colours, and maintenance settings after installation.
  grep -q '^APP_ENVIRONMENT_ONLY=' .env && sed -i 's|^APP_ENVIRONMENT_ONLY=.*|APP_ENVIRONMENT_ONLY=false|' .env || echo 'APP_ENVIRONMENT_ONLY=false' >>.env
  # Older MySQL/MariaDB can silently generate a zero default for a second
  # TIMESTAMP column. Newer Reviactyl migrations use multiple timestamps with
  # no default, so enable explicit defaults before Laravel opens its connection.
  mariadb -e "SET GLOBAL explicit_defaults_for_timestamp = ON" 2>/dev/null || true
  mariadb -e "SET GLOBAL sql_mode = REPLACE(REPLACE(@@GLOBAL.sql_mode, 'NO_ZERO_IN_DATE', ''), 'NO_ZERO_DATE', '')" 2>/dev/null || true
  php artisan migrate --seed --force
  if [[ ${AUTO_MODE:-0} == 1 ]]; then
    php artisan p:user:make \
      --email="${ADMIN_USER}@${DOMAIN}" \
      --username="$ADMIN_USER" \
      --name-first=Owner \
      --name-last=Admin \
      --password="$ADMIN_PASS" \
      --admin=1
  else
    php artisan p:user:make
  fi
  chown -R www-data:www-data "$PANEL_DIR"
  chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

  write_nginx_config
  cat >/etc/systemd/system/reviq.service <<EOF
[Unit]
Description=Reviactyl Queue Worker
After=redis-server.service
[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
  echo '* * * * * www-data php /var/www/reviactyl/artisan schedule:run >> /dev/null 2>&1' >/etc/cron.d/reviactyl
  nginx -t
  systemctl daemon-reload
  systemctl enable --now nginx php8.3-fpm redis-server reviq

  if [[ $DIRECT_MODE == 1 ]]; then
    echo "[DIRECT] Memasang HTTPS Let's Encrypt langsung ke IP publik."
    certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email -d "$PANEL_FQDN"
  else
    # Cloudflare Tunnel: login membutuhkan browser, jadi sengaja interaktif.
    curl -fL -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    wait_for_apt
    dpkg -i /tmp/cloudflared.deb || { wait_for_apt; apt -f install -y; }
    TUNNEL_NAME="reviactyl-${PANEL_SUB}-$(date +%s)"
    echo "Login ke akun Cloudflare yang memiliki zone $DOMAIN."
    cloudflared tunnel login
    cloudflared tunnel create "$TUNNEL_NAME"
    TUNNEL_ID=$(cloudflared tunnel list --output json | jq -r --arg name "$TUNNEL_NAME" '.[] | select(.name == $name) | .id')
    [[ -n $TUNNEL_ID && $TUNNEL_ID != null ]] || die "UUID tunnel tidak ditemukan. Jalankan: cloudflared tunnel list"
    cloudflared tunnel route dns "$TUNNEL_NAME" "$PANEL_FQDN"
    cloudflared tunnel route dns "$TUNNEL_NAME" "$NODE_FQDN"
    write_tunnel_config
    cloudflared --config "$REVIA_CF_CONFIG" tunnel ingress validate
    # `cloudflared service install` mencoba menjalankan service sendiri dan pada
    # Debian kadang berakhir timeout walaupun tunnel/config sudah valid. Tulis
    # unit khusus secara eksplisit agar start dikelola systemd dengan stabil.
    cat >"/etc/systemd/system/$REVIA_CF_SERVICE.service" <<EOF
[Unit]
Description=Cloudflare Tunnel for Reviactyl
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config $REVIA_CF_CONFIG tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$REVIA_CF_SERVICE"
    # Jangan biarkan systemctl menunggu tanpa batas ketika connector Cloudflare
    # sedang bermasalah. Statusnya diperiksa jelas agar bot dapat memberi hasil.
    timeout 60s systemctl restart "$REVIA_CF_SERVICE" || {
      journalctl -u "$REVIA_CF_SERVICE" --no-pager -n 25 >&2 || true
      die "Service Cloudflare Tunnel gagal aktif dalam 60 detik."
    }
    systemctl is-active --quiet "$REVIA_CF_SERVICE" || die "Service Cloudflare Tunnel tidak aktif."
    check_public_dns "$PANEL_FQDN" "$NODE_FQDN"
  fi

  # Reviactyl Agent (pengganti Wings)
  wait_for_apt
  curl --connect-timeout 20 --max-time 300 -fsSL https://get.docker.com/ | CHANNEL=stable bash
  systemctl enable --now docker
  mkdir -p /etc/reviactyl
  curl -fL -o /usr/local/bin/agent "https://github.com/reviactyl/agent/releases/latest/download/agent_linux_$([[ "$(uname -m)" == x86_64 ]] && echo amd64 || echo arm64)"
  chmod +x /usr/local/bin/agent
  cat >/etc/systemd/system/agent.service <<'EOF'
[Unit]
Description=Reviactyl Agent
After=docker.service
Requires=docker.service
PartOf=docker.service
[Service]
User=root
WorkingDirectory=/etc/reviactyl
LimitNOFILE=4096
PIDFile=/var/run/agent/daemon.pid
ExecStart=/usr/local/bin/agent
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  TUNNEL_NAME=${TUNNEL_NAME:-}
  TUNNEL_ID=${TUNNEL_ID:-}
  save_state

  # Pemeriksaan akhir: memastikan Nginx benar-benar melayani aplikasi untuk FQDN panel.
  systemctl restart nginx
  [[ $DIRECT_MODE == 1 ]] || systemctl restart "$REVIA_CF_SERVICE"
  HTTP_CODE=$(curl -sS -o /tmp/reviactyl-panel-health.html -w '%{http_code}' -H "Host: $PANEL_FQDN" http://127.0.0.1/ || true)
  if [[ $HTTP_CODE != 200 && $HTTP_CODE != 302 && $HTTP_CODE != 301 ]]; then
    echo "[HEALTH_ERROR] Panel origin memberi HTTP $HTTP_CODE untuk $PANEL_FQDN" >&2
    echo "[HEALTH_ERROR] Periksa konflik Nginx: nginx -T | grep -n '$PANEL_FQDN'" >&2
    exit 1
  fi
  echo "[HEALTH_OK] Nginx origin panel merespons HTTP $HTTP_CODE"

  echo
  echo "SELESAI: buka https://$PANEL_FQDN"
  if [[ $DIRECT_MODE == 1 ]]; then
    echo "Buat Node dengan FQDN/IP publik $NODE_FQDN dan port 8080; pilih HTTP/tanpa SSL dan Not Behind Proxy."
  else
    echo "Buat Node dengan FQDN $NODE_FQDN dan port $AGENT_PORT."
  fi
  echo "Salin konfigurasi dari tab Node > Configuration ke /etc/reviactyl/config.yml, lalu jalankan:"
  echo "  systemctl enable --now agent"
  echo "Untuk ganti domain nanti: bash $0 ubah-domain"
}

change_domain() {
  need_root
  [[ -f $STATE_FILE ]] || die "Data instalasi tidak ditemukan: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  ask_network
  cloudflared tunnel route dns "$TUNNEL_ID" "$PANEL_FQDN"
  cloudflared tunnel route dns "$TUNNEL_ID" "$NODE_FQDN"
  write_tunnel_config
  write_nginx_config
  sed -i "s|^APP_URL=.*|APP_URL=https://$PANEL_FQDN|" "$PANEL_DIR/.env"
  grep -q '^TRUSTED_PROXIES=' "$PANEL_DIR/.env" || echo 'TRUSTED_PROXIES=*' >>"$PANEL_DIR/.env"
  cd "$PANEL_DIR"
  php artisan optimize:clear
  nginx -t
  systemctl restart nginx "$REVIA_CF_SERVICE" reviq
  save_state
  echo "Domain panel baru: https://$PANEL_FQDN"
  echo "Buat/perbarui Node ke $NODE_FQDN:$AGENT_PORT, lalu salin ulang konfigurasi Node ke /etc/reviactyl/config.yml dan restart Agent."
}

case "${1:-}" in
  install) install_panel ;;
  ubah-domain) change_domain ;;
  *) echo "Pakai: sudo bash $0 {install|ubah-domain}"; exit 2 ;;
esac
