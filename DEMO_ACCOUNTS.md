# Akun demo lokal

Semua akun berada di Firebase Emulator dengan project `demo-tb-monitoring`.
Password bersama tersimpan hanya di `.demo_accounts.local.json`, yang diabaikan
oleh Git. Jangan salin file lokal tersebut ke repositori atau gunakan password
ini pada layanan produksi.

| Role | Akun |
| --- | --- |
| Caregiver | `demo.pendamping01@example.test` |
| Caregiver | `demo.pendamping02@example.test` |
| Patient | `demo.pasien01@example.test` sampai `demo.pasien15@example.test` |

Password bersama tersimpan di `.demo_accounts.local.json` yang diabaikan oleh Git.
Ambil dari file lokal tersebut hanya untuk presentasi emulator; jangan
menyalinnya ke repositori atau memakai password ini di layanan produksi.

## Menjalankan generator

Nyalakan Auth dan Firestore Emulator pada port 9199 dan 8180 dengan project
`demo-tb-monitoring`. Jangan nyalakan Functions Emulator saat membuat profil
pasien. Script memeriksa keadaan ini dan berhenti jika Functions Emulator aktif.

Di PowerShell, dari folder proyek:

```powershell
$env:FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9199"
$env:FIRESTORE_EMULATOR_HOST = "127.0.0.1:8180"
$env:GCLOUD_PROJECT = "demo-tb-monitoring"
node scripts/seed_demo_accounts.cjs
```

Script idempotent untuk 17 UID demo yang telah ditentukan. Ia menolak project,
host emulator, Functions Emulator aktif/terdaftar di Hub, atau dokumen profil/kode
pasien yang tidak cocok; akun lain tidak dihapus atau diubah. Script hanya membuat
akun Auth dan profil. Profil demo memiliki `isDemo: true` sebagai penanda UI serta
custom claim Auth `isDemo: true` yang dikelola Admin SDK sebagai sumber tepercaya
bagi Cloud Functions. Field Firestore tidak dapat ditulis klien dan bukan sumber
keputusan trigger. Profil pasien memiliki `treatmentGroup` dan
`treatmentStartedAt` karena diwajibkan model/Rules aplikasi. Script menulis
`users/{uid}` dan kode pairing `patientCodes/{code}`.

## Catatan kondisi saat akun pertama dibuat

Saat pembuatan awal, trigger Functions memproses event profil dan menghasilkan
15 dokumen `treatments` serta 60 `btaExaminations`, selain 17 profil dan 15 kode
pasien. Dokumen medis lama ini tidak diubah atau dihapus. Trigger kini melewati
akun dengan custom claim Auth demo; pasien non-demo tetap mengikuti inisialisasi
sebelumnya. Generator menolak berjalan jika Functions Emulator aktif. Data medis
untuk akun demo tidak dibuat otomatis.
