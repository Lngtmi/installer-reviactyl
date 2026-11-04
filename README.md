# Installer Reviactyl

Script installer **Reviactyl Panel + Agent (Wings)** untuk VPS. Jaringan VPS **terdeteksi otomatis** di awal:

- **VPS dengan IPv4 publik → mode Direct** — HTTPS langsung dari VPS (Let's Encrypt), tanpa tunnel
- **VPS di belakang NAT → mode Cloudflare Tunnel** — tanpa IP publik tetap bisa online

Satu file, tanpa dependensi script lain:

```
install-reviactyl.sh
```

## Sistem yang didukung

- Ubuntu 22.04 / 24.04
- Debian 12 (Bookworm)
- VPS/KVM penuh dengan systemd, dijalankan sebagai **root**

## Cara Install — Pilih 2 Model

### Model 1 — Bash (1 perintah, langsung jalan dari GitHub)

Tidak perlu download apa pun. Jalankan di VPS sebagai root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lngtmi/installer-reviactyl/main/install-reviactyl.sh) install
```

Script akan bertanya domain, subdomain, dan data admin satu per satu (mode interaktif).

> **Mode Direct (IPv4 publik):** sebelum instalasi lanjut, script menampilkan catatan berisi 2 **A record** yang wajib kamu buat lebih dulu di panel DNS domainmu — subdomain panel dan subdomain node diarahkan ke IP publik VPS. Script memeriksa sendiri apakah kedua record sudah benar (lewat resolver publik, jadi tidak tertipu cache DNS lokal VPS), dan **berhenti di awal** dengan pesan jelas bila belum — supaya tidak ada lagi kegagalan sertifikat (NXDOMAIN) di tengah instalasi. Mode Tunnel tidak butuh record manual; record-nya dibuatkan otomatis saat kamu login Cloudflare di tengah instalasi.

Mode otomatis (tanpa pertanyaan):

```bash
AUTO_MODE=1 DOMAIN=contoh.com ADMIN_USER=admin@contoh.com ADMIN_PASS='password_admin_panel' \
  bash <(curl -fsSL https://raw.githubusercontent.com/Lngtmi/installer-reviactyl/main/install-reviactyl.sh) install
```

> Gunakan selalu bentuk `bash <(curl ...)` di atas, **bukan** `curl ... | bash` — bentuk pipa merusak pertanyaan interaktif script.

### Model 2 — Source Code (download / clone dulu)

```bash
git clone https://github.com/Lngtmi/installer-reviactyl.git
cd installer-reviactyl
sudo bash install-reviactyl.sh install
```

Atau unduh ZIP dari tombol **Code → Download ZIP** di halaman repo ini, ekstrak, lalu jalankan `sudo bash install-reviactyl.sh install`.

## Panduan Mengisi Wizard (mode interaktif)

Setelah pertanyaan domain dan (untuk mode Direct) pemeriksaan A record selesai, installer membuka wizard Reviactyl. Isi **persis** seperti ini, urut dari atas:

**Wizard setup:**
1. Egg Author Email: email kamu sendiri
2. Application URL: `https://<subdomain-panel>.<domain>` — persis yang ditampilkan script
3. Application Timezone: `Asia/Jakarta`
4. Cache Driver: `redis`
5. Session Driver: `redis`
6. Queue Driver: `redis`
7. Enable UI based settings editor: `yes`
8. Enable telemetry: `no`
9. Redis Host / Redis Password / Redis Port: **Enter saja** (pakai bawaan; password dikosongkan)

**Wizard database:**
10. **Database Driver: `mariadb`** — ⚠️ JANGAN tekan Enter! Pilihan bawaannya adalah **SQLite** dan instalasi akan **gagal** ("Database file ... does not exist")
11. Database Host: Enter (127.0.0.1)
12. Database Port: Enter (3306)
13. Database Name: `panel`
14. Database Username: `pterodactyl`
15. Database Password: password yang ditampilkan script di blok "PANDUAN MENGISI WIZARD" sebelum wizard dibuka (berubah setiap instalasi — jangan pakai dari instalasi sebelumnya)

**Wizard email:**
16. Mail Driver: `sendmail` — paling simpel, tidak ditanya kredensial server apa pun (pilihan lain: smtp/mailgun/mandrill/postmark butuh akun/API key; email beneran bisa diatur belakangan dari panel)
17. Mail From Address: `no-reply@<domain kamu>`
18. Mail From Name: `Reviactyl`

**Terakhir:** buat akun admin panel — email, username, nama, dan password login (minimal 8 karakter), bebas sesuai keinginanmu. Setelah itu script berjalan sendiri sampai muncul tulisan **SELESAI** beserta alamat panelnya.

### Variabel mode otomatis

| Variable | Wajib | Keterangan |
| --- | --- | --- |
| `DOMAIN` | Ya (mode otomatis) | Domain utama, mis. `contoh.com` |
| `ADMIN_USER` | Ya (mode otomatis) | Email admin panel |
| `ADMIN_PASS` | Ya (mode otomatis) | Password admin panel |
| `PANEL_SUB` | Tidak | Subdomain panel, default `panel` → `panel.contoh.com` |
| `NODE_SUB` | Tidak | Subdomain node, default `node` → `node.contoh.com` |
| `DIRECT_MODE` | Tidak | `1` = tanpa Cloudflare Tunnel (VPS IP publik). Bila tidak diisi, mode dipilih otomatis dari hasil deteksi jaringan VPS |
| `AUTO_MODE` | Tidak | `1` = mode otomatis tanpa pertanyaan |

## Ganti domain setelah terinstall

```bash
sudo bash install-reviactyl.sh ubah-domain
```

## Catatan

- Installer berhenti dengan pesan error yang jelas bila OS tidak didukung atau data wajib belum diisi — tidak jalan setengah-setengah secara diam-diam.
- File yang diubah/diinstall tercatat di `/root/reviactyl-installer.env` di VPS.
- Simpan password admin dan data login panelmu sendiri; script ini tidak menyimpan kredensial apa pun di repository.

## Kontak

Ada pertanyaan atau butuh bantuan? Hubungi saya di Telegram: [@pratamanie](https://t.me/pratamanie)

---
SOURCE CODE BY PRATAMA
