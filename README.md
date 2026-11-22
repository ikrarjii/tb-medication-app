# Medicine Control

Aplikasi Flutter/Firebase untuk pemantauan kepatuhan minum obat secara real-time
antara pasien dan satu atau lebih pendamping.

## Fitur utama

- Autentikasi dan dashboard terpisah untuk pasien dan pendamping.
- Kode pasien acak 8 karakter, pairing mandiri, dan dukungan banyak pendamping.
- Pendaftaran pasien mewajibkan nama, umur, jenis kelamin, email, nomor telepon,
  kata sandi aman, dan golongan pengobatan. Kategori Anak/Dewasa dihitung dan
  disimpan otomatis dari umur.
- Jadwal terapi Golongan 1 dibuat otomatis: setiap hari pada bulan 1–2, lalu
  Senin/Rabu/Jumat pada bulan 3–6.
- Golongan Lain tersedia untuk pencatatan profil, tetapi belum mempunyai aturan
  penjadwalan terapi.
- Pendamping/PMO hanya mengatur satu waktu minum obat yang berlaku pada seluruh
  hari terapi; pasien tidak dapat mengubah waktu atau aturan jadwal.
- Konfirmasi `taken`, `late`, atau `missed` oleh pasien beserta medication log.
- Indikator kepatuhan hijau, kuning, dan merah dari riwayat dosis.
- Alarm obat Android layar penuh dengan suara berulang, aksi diminum, tunda
  5 menit, dan matikan alarm.
- Alarm lokal dipulihkan setelah perangkat dinyalakan ulang; alarm lama
  dibatalkan saat jadwal diubah, dihapus, atau diselesaikan.
- Push perubahan jadwal diproyeksikan langsung ke AlarmManager oleh receiver
  native, termasuk saat proses Flutter sedang tidak berjalan.
- Respons alarm disimpan dalam antrean native yang durable sehingga beberapa
  dosis bersamaan dan respons sebelum aplikasi terbuka tidak saling menimpa.
- Push FCM dan pusat notifikasi real-time untuk pasien dan pendamping.
- Push backend menggunakan outbox Firestore ber-lease dan retry agar kegagalan
  sementara tidak menghilangkan notifikasi.
- Pusat notifikasi real-time pendamping.
- Aturan Firestore membatasi data pasien hanya untuk pasien dan pendamping yang
  mempunyai dokumen pairing aktif.
- Empat jadwal monitoring BTA dibuat otomatis relatif terhadap tanggal mulai
  terapi dalam rentang bulan ke-1, ke-3, ke-5, dan ke-6. Hari pemeriksaan tidak
  ditetapkan oleh aplikasi. Jadwal tidak dapat diubah oleh pendamping;
  pendamping hanya mengisi hasil positif atau negatif serta catatan opsional.
- Hasil akhir TB dihitung otomatis oleh pohon keputusan deterministik menjadi
  `CURED`, `TREATMENT COMPLETED`, `FAILED`, atau `TREATMENT IN PROGRESS`.
- Konversi BTA dan kemungkinan reversal dideteksi dari urutan pemeriksaan.
  Reversal baru dianggap terkonfirmasi setelah hasil positif ulang bertipe
  pemeriksaan konfirmasi; satu hasil positif terisolasi tidak menetapkan gagal.
- Kepatuhan obat dihitung oleh `AdherenceDecisionTree` yang terpisah: minimal
  95% `SANGAT PATUH`, 80–94,99% `CUKUP PATUH`, dan di bawah 80%
  `KEPATUHAN RENDAH`. Hasil ini tidak menjadi input
  `TreatmentOutcomeDecisionTree` dan tidak dapat mengubah outcome terapi.

## Struktur data Firestore

- `users/{uid}`: profil, role, kode pasien, umur, kategori umur, jenis kelamin,
  golongan/tanggal mulai terapi, waktu obat dari PMO, pengaturan, dan FCM token.
- `patientCodes/{code}`: lookup invitation code ke pasien (get-only).
- `pairings/{caregiverId}_{patientId}`: hubungan pendamping-pasien.
- `medicines/{id}`: satu dosis terjadwal yang dibuat deterministik dari aturan
  terapi, revisi waktu, status alarm, waktu tunda, dan status real-time.
- `medicationLogs/{medicineId}`: catatan hasil yang immutable dengan waktu
  respons/taken/missed dari server.
- `notifications/{id}`: inbox notifikasi per penerima.
- `reminders/{id}`: pengingat manual dari pendamping.
- `treatments/{patientId}`: tanggal mulai/estimasi/selesai aktual, status terapi,
  kondisi kegagalan yang telah dikonfirmasi, hasil pohon keputusan, dan jalur
  alasan audit.
- `btaExaminations/{id}`: tipe pemeriksaan, tanggal jadwal, tanggal aktual, hasil
  BTA, catatan, dan UID pendamping yang memasukkan data.

Akun pasien lama yang belum memiliki kode akan memperoleh kode secara otomatis
pada login berikutnya. Golongan terapi dan tanggal mulai default untuk akun lama
juga diinisialisasi sebagai Golongan 1 saat pasien login; umur dan jenis kelamin
dapat dilengkapi melalui menu Edit Profil.

## Menjalankan aplikasi

```sh
flutter pub get
flutter run
```

Konfigurasi Firebase aplikasi saat ini tersedia untuk Android. Aktifkan Firebase
Authentication Email/Password, Cloud Firestore, dan Cloud Messaging pada proyek
Firebase yang sama.

## Deploy backend

Instal Firebase CLI, login, lalu pilih proyek Firebase sebelum deploy:

```sh
firebase use <project-id>
firebase deploy --only firestore:rules,firestore:indexes
cd functions
npm install
cd ..
firebase deploy --only functions
```

`checkMedicationDeadlines` berjalan setiap menit. Jadwal menjadi jatuh tempo
pada waktunya, tetap tepat waktu sampai 10 menit setelah jadwal, terlambat jika
melewati batas tersebut, dan otomatis terlewat setelah 18 jam. Pendamping
menerima notifikasi jika pasien belum mengonfirmasi obat pada menit ke-10.
Pasien masih dapat mengonfirmasi dosis otomatis-terlewat sebagai diminum
terlambat sampai 24 jam setelah jadwal. Pemrosesan dipaginasi dan idempotent;
`retryPushOutbox` mengirim ulang push yang gagal. Scheduled Functions memerlukan
paket Blaze/Cloud Scheduler.

Tanpa deploy Functions, sinkronisasi data, pairing, CRUD jadwal, konfirmasi
pasien, notifikasi lokal pasien, dan inbox event konfirmasi tetap berfungsi.
Push saat aplikasi tertutup serta event otomatis jadwal tiba/terlambat memerlukan
Functions yang sudah dideploy.

### Emulator lokal untuk notifikasi

Jalankan seluruh emulator yang diperlukan dengan proyek demo. Pub/Sub wajib
disertakan agar fungsi jadwal seperti `checkMedicationDeadlines` aktif:

```powershell
firebase emulators:start --config firebase.demo.json --project demo-tb-monitoring --only auth,firestore,functions,pubsub
```

Kemudian jalankan aplikasi Flutter dalam mode debug dengan
`--dart-define=USE_FIREBASE_EMULATOR=true`. Untuk Android Emulator, host
Firestore/Auth pada aplikasi diarahkan ke `10.0.2.2`; Functions berjalan di
server emulator dan menggunakan Firestore emulator dari proyek demo yang sama.

`checkBtaExaminationReminders` berjalan setiap hari pukul 08.00 WITA. Pasien
menerima pengingat ketika rentang bulan pemeriksaan dimulai. Pendamping menerima
pemberitahuan rentang yang sama dan peringatan jika hasil belum diisi setelah
rentang bulan berakhir. Trigger BTA/status terapi menghitung ulang hasil dan
menyimpan alasan klasifikasi secara otomatis. Deploy `firestore:indexes` bersama
rules dan functions karena pekerjaan pengingat memakai indeks gabungan BTA.

## Catatan Android

Android 13+ meminta izin notifikasi. Aplikasi membuka halaman akses alarm tepat
waktu pada Android 12+ dan akses layar penuh pada Android 14+ bila izin belum
tersedia; alarm inexact/heads-up tetap menjadi fallback jika akses ditolak.
Force-stop menonaktifkan alarm sampai aplikasi dibuka kembali; Do Not Disturb
juga dapat membatasi suara sesuai pengaturan perangkat.
