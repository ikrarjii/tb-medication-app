# Rancangan data demo production

Status: rancangan disetujui; seeder production sudah disiapkan. Belum ada akun atau data yang ditulis ke Firebase production.

## Akun

| Email login | Peran | Pasien yang terhubung | Kode pasien |
| --- | --- | --- | --- |
| `demo.pendamping01@example.test` | Pengawas | Pasien 01–04 | — |
| `demo.pendamping02@example.test` | Pengawas | Pasien 05–08 | — |
| `demo.pasien01@example.test` | Pasien | Pengawas 01 | `DMPA9001` |
| `demo.pasien02@example.test` | Pasien | Pengawas 01 | `DMPA9002` |
| `demo.pasien03@example.test` | Pasien | Pengawas 01 | `DMPA9003` |
| `demo.pasien04@example.test` | Pasien | Pengawas 01 | `DMPA9004` |
| `demo.pasien05@example.test` | Pasien | Pengawas 02 | `DMPA9005` |
| `demo.pasien06@example.test` | Pasien | Pengawas 02 | `DMPA9006` |
| `demo.pasien07@example.test` | Pasien | Pengawas 02 | `DMPA9007` |
| `demo.pasien08@example.test` | Pasien | Pengawas 02 | `DMPA9008` |

Nama profil menggunakan nama jelas seperti “Pasien Demo 01”. Semua akun ditandai sebagai demo pada Auth claim dan profil. Password demo dibuat acak saat penyiapan, tidak memakai password akun emulator, dan ditaruh pada file lokal yang diabaikan Git.

## Kasus pengobatan

| Pasien | Kasus yang ditampilkan | Riwayat BTA demo | Kepatuhan contoh |
| --- | --- | --- | --- |
| 01 | Sembuh | Positif → negatif → negatif | Sangat tinggi |
| 02 | Pengobatan selesai | Negatif tetap negatif | Sedang |
| 03 | Gagal, BTA tetap positif | Positif berulang | Rendah; beberapa dosis terlewat |
| 04 | Pengobatan berjalan | Positif, belum konversi | Tinggi |
| 05 | Pengobatan berjalan setelah konversi | Positif → negatif | Sangat tinggi |
| 06 | Kemungkinan reversi | Positif → negatif → positif; belum ada konfirmasi | Sedang |
| 07 | Reversi terkonfirmasi | Positif → negatif → positif → konfirmasi positif | Rendah |
| 08 | Pengobatan berjalan | Belum ada hasil tindak lanjut | Ada dosis terlambat dan belum dijawab |

## Isi yang direncanakan

- 10 akun Firebase Authentication dan 10 profil.
- 8 kode pasien dan 8 relasi pasien–pengawas.
- 8 ringkasan hasil pengobatan serta 33 catatan pemeriksaan BTA.
- Maksimal 56 jadwal dosis contoh dan log untuk dosis yang sudah dijawab.
- Beberapa notifikasi contoh pada inbox pengawas agar layar notifikasi tidak kosong.
- Data diberi label demo, nama dan nomor telepon sintetis. Tidak memakai data pasien asli.

Penyiapan harus berhenti jika UID/email/kode yang direncanakan sudah dipakai oleh akun atau data non-demo. Tidak menghapus data dan tidak mengubah akun production yang sudah ada.

## Menjalankan seeder

Seeder ada di `scripts/seed_demo_production.cjs`. Mode default adalah dry-run dan hanya menulis bila argumen `--apply` diberikan. Target project dikunci ke `drugcontrol-a35e2`, seeder menolak endpoint emulator, dan memeriksa benturan sebelum membuat akun atau dokumen.

```powershell
node scripts/seed_demo_production.cjs
node scripts/seed_demo_production.cjs --apply
```

Jalankan dari folder proyek dengan kredensial Admin SDK yang berwenang untuk Firebase Authentication dan Firestore. Password akun acak disimpan lokal di `.demo_production_credentials.local.json`, yang diabaikan Git.
