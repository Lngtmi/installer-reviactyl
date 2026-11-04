# Installer Reviactyl

Script **Reviactyl Panel + Agent (Wings)** untuk VPS, dengan menu 2 pilihan saat dijalankan:

1. **Install Panel Reviactyl** — pasang panel lengkap di VPS ini
2. **Setup Agent** — pasang Agent (daemon node) di VPS ini untuk panel yang sudah ada

Jaringan VPS **terdeteksi otomatis** di awal:

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

## Cara Install — Bash (1 perintah)

Ini satu-satunya cara install yang disarankan. Tidak perlu download apa pun — jalankan di VPS sebagai root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lngtmi/installer-reviactyl/main/install-reviactyl.sh)
```

Muncul menu — pilih **1** untuk install panel, atau **2** untuk setup Agent. (Argumen `install` dan `setup-agent` juga bisa ditambahkan di akhir perintah untuk lompat langsung ke pilihan itu.)

> **Mode Direct (IPv4 publik):** sebelum instalasi lanjut, script menampilkan catatan berisi 2 **A record** yang wajib kamu buat lebih dulu di panel DNS domainmu — subdomain panel dan subdomain node diarahkan ke IP publik VPS. Script memeriksa sendiri apakah kedua record sudah benar (lewat resolver publik, jadi tidak tertipu cache DNS lokal VPS), dan **berhenti di awal** dengan pesan jelas bila belum — supaya tidak ada lagi kegagalan sertifikat (NXDOMAIN) di tengah instalasi. Mode Tunnel tidak butuh record manual; record-nya dibuatkan otomatis saat kamu login Cloudflare di tengah instalasi.

> Gunakan selalu bentuk `bash <(curl ...)` di atas, **bukan** `curl ... | bash` — bentuk pipa merusak pertanyaan interaktif script.

## Semua Diisi Otomatis — Tanpa Wizard

Installer ini **tidak memakai wizard bawaan Reviactyl** (`p:environment:setup` dan kawan-kawan). Wizard itu pilihan bawaannya menyesatkan — driver database SQLite, username database yang tidak pernah dibuat, mailer SMTP tanpa server — dan terbukti membuat instalasi gagal di tengah jalan.

Sebagai gantinya, script menanyakan semua yang perlu **di awal saja**: domain, subdomain panel, subdomain node, lalu email + username + password admin panel. Setelah kamu mengetik `HAPUS`, seluruh konfigurasi (URL panel, timezone Asia/Jakarta, cache/session/queue Redis, database MariaDB, email) **diisi otomatis oleh installer** dan instalasi berjalan sampai muncul tulisan **SELESAI** tanpa pertanyaan apa pun di tengah.

Catatan email: mailer disetel ke mode `log` — email dicatat ke log panel, tidak dikirim keluar. Itu cukup untuk menjalankan panel; kalau nanti mau email beneran terkirim (mis. reset password), atur SMTP dari dalam panel setelah instalasi selesai.

## Pilihan 2 — Setup Agent

Untuk menambah node ke panel yang **sudah ada** (panelnya di VPS lain, atau di VPS ini juga). Alurnya:

1. Script mendeteksi jaringan VPS ini (IPv4 publik → mode Direct, NAT → mode Tunnel) dan menampilkan pengaturan node yang harus kamu buat di panel: FQDN, SSL, Behind Proxy, dan port (Direct: 8080 tanpa proxy; Tunnel: 443 di belakang proxy).
2. Khusus mode Direct: kamu membuat A record FQDN node ke IP VPS ini (script memeriksa sendiri lewat resolver publik), lalu script menerbitkan sertifikat Let's Encrypt untuk node itu.
3. Docker + Agent dipasang otomatis.
4. Kamu menempel isi **config.yml** dari panel (tab Node → Configuration) — selesai, Agent dinyalakan dan node menyala hijau di panel.

## Ganti domain setelah terinstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lngtmi/installer-reviactyl/main/install-reviactyl.sh) ubah-domain
```

## Catatan

- Installer berhenti dengan pesan error yang jelas bila OS tidak didukung atau data wajib belum diisi — tidak jalan setengah-setengah secara diam-diam.
- File yang diubah/diinstall tercatat di `/root/reviactyl-installer.env` di VPS.
- Simpan password admin dan data login panelmu sendiri; script ini tidak menyimpan kredensial apa pun di repository.

## Kontak

Ada pertanyaan atau butuh bantuan? Hubungi saya di Telegram: [@pratamanie](https://t.me/pratamanie)

---
SOURCE CODE BY PRATAMA
