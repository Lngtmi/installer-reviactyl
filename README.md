# Installer Reviactyl

Script installer **Reviactyl Panel + Agent (Wings)** untuk VPS — lengkap dengan Cloudflare Tunnel (untuk VPS tanpa IP publik) atau mode direct (VPS dengan IP publik).

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

### Variabel mode otomatis

| Variable | Wajib | Keterangan |
| --- | --- | --- |
| `DOMAIN` | Ya (mode otomatis) | Domain utama, mis. `contoh.com` |
| `ADMIN_USER` | Ya (mode otomatis) | Email admin panel |
| `ADMIN_PASS` | Ya (mode otomatis) | Password admin panel |
| `PANEL_SUB` | Tidak | Subdomain panel, default `panel` → `panel.contoh.com` |
| `NODE_SUB` | Tidak | Subdomain node, default `node` → `node.contoh.com` |
| `DIRECT_MODE` | Tidak | `1` = tanpa Cloudflare Tunnel (VPS IP publik), default tunnel |
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
