# Presensia

Presensia adalah aplikasi Flutter untuk presensi karyawan berbasis pengenalan wajah, tracker pekerjaan harian, kalender kehadiran, dan laporan performa.

Project ini memakai kamera perangkat, Google ML Kit Face Detection, MobileFaceNet TFLite, SQLite lokal untuk cache embedding, dan Supabase sebagai backend utama.

## Fitur Utama

- Auth Supabase: login, register, reset password, dan session.
- Pendaftaran wajah menggunakan multi-sampel dari kamera.
- Face alignment berbasis landmark mata sebelum masuk ke MobileFaceNet.
- Penyimpanan beberapa embedding referensi per user untuk meningkatkan akurasi.
- Presensi check-in dan check-out dengan verifikasi wajah.
- Switch dev di Profile untuk mengaktifkan atau menonaktifkan kedip saat presensi.
- Face AI Lab untuk menguji foto dari galeri/kamera terhadap data wajah terdaftar.
- Popup sukses check-in dengan pesan semangat kerja.
- Popup sukses check-out dengan pesan selamat pulang.
- Tracker project dan worklog harian.
- Kalender presensi, worklog, izin/libur, dan marker tanggal.
- Laporan performa dan export PDF.
- Reminder lokal untuk check-in/check-out.

## Pipeline Wajah

### Pendaftaran Wajah

```text
Buka Daftarkan Wajah
  -> kamera aktif
  -> user mengikuti tahap frontal, kiri ringan, dan kanan ringan
  -> sistem mengambil total 9 sampel valid
  -> ML Kit mendeteksi wajah, landmark, pose, dan kualitas dasar
  -> wajah di-align berdasarkan posisi mata
  -> crop wajah dan resize ke 112x112
  -> MobileFaceNet membuat embedding 192 dimensi
  -> embedding dinormalisasi L2
  -> sistem menyimpan 6 embedding referensi:
       frontal avg, frontal best,
       kiri avg, kiri best,
       kanan avg, kanan best
  -> embedding disimpan lokal dan disinkronkan ke Supabase
```

Strategi 6 embedding dipakai agar presensi tetap kuat untuk wajah frontal, tetapi masih toleran terhadap sedikit variasi pose.

### Presensi Check-In / Check-Out

```text
Buka tab Absensi
  -> tekan tombol presensi
  -> kamera memverifikasi wajah
  -> jika switch dev kedip aktif, user diminta kedip dulu
  -> sistem mengambil frame terbaik
  -> ML Kit mendeteksi wajah dan quality gate
  -> face alignment + crop + resize 112x112
  -> MobileFaceNet membuat query embedding
  -> query dibandingkan ke 6 embedding referensi user
  -> skor tertinggi dipakai sebagai hasil akhir
  -> jika cosine similarity >= 0.65, presensi berhasil
```

Saat presensi berhasil, aplikasi menampilkan popup sukses. Check-in memberi pesan semangat kerja, sedangkan check-out memberi pesan selamat pulang.

### Face AI Lab

Face AI Lab tersedia dari Profile untuk membantu debugging dan kalibrasi sebelum liveness presensi difinalkan.

Lab memakai embedding hasil pendaftaran wajah sebagai target, lalu user bisa memilih foto uji dari galeri atau kamera. Hasil yang ditampilkan meliputi:

- Cosine similarity.
- Status threshold 0.65, 0.70, dan 0.75.
- Quality score.
- Pose Euler X/Y/Z.
- Ukuran wajah.
- Inference time.
- Distance.
- Best target dari 6 embedding referensi.

## Teknologi

- Flutter / Dart
- Supabase
- Camera
- Google ML Kit Face Detection
- TFLite Flutter
- MobileFaceNet
- SQLite / sqflite
- Image processing dengan package `image`
- Image picker
- PDF dan Printing
- Local Notifications

## Struktur Folder

```text
lib/
  features/
    attendance/      # UI presensi, kamera, dan flow face match
    auth/            # login, register, reset password, splash
    calendar/        # kalender kehadiran dan worklog
    enrollment/      # pendaftaran wajah
    home/            # dashboard utama
    main_nav/        # navigasi utama aplikasi
    profile/         # profil, Face AI Lab, dan dev switch
    report/          # laporan dan export PDF
    tracker/         # project dan worklog
  shared/
    database/        # database lokal embedding
    models/          # model aplikasi
    providers/       # provider notifikasi
    services/        # service Supabase, attendance, face, PDF, dll
    store/           # state utama aplikasi
    theme/           # warna dan tema aplikasi

assets/
  models/
    mobilefacenet.tflite

supabase/
  schema.sql
```

## Prasyarat

- Flutter SDK sesuai environment project.
- Android Studio atau VS Code dengan Flutter plugin.
- Perangkat Android fisik sangat disarankan untuk kamera dan ML Kit.
- Project Supabase aktif.
- Model MobileFaceNet tersedia di `assets/models/mobilefacenet.tflite`.

## Setup Project

1. Masuk ke folder project.

```bash
cd face_recognizer
```

2. Install dependency Flutter.

```bash
flutter pub get
```

3. Pastikan asset model tersedia.

```text
assets/models/mobilefacenet.tflite
```

4. Pastikan asset sudah terdaftar di `pubspec.yaml`.

```yaml
flutter:
  assets:
    - public/
    - assets/models/mobilefacenet.tflite
```

5. Siapkan database Supabase.

Jalankan isi file berikut di Supabase SQL Editor:

```text
supabase/schema.sql
```

6. Pastikan konfigurasi Supabase sesuai di:

```text
lib/shared/services/supabase_client.dart
```

7. Jalankan aplikasi.

```bash
flutter run
```

## Cara Uji Manual

1. Register atau login.
2. Buka Profile.
3. Buka `Daftarkan Wajah`.
4. Ikuti tahap pendaftaran wajah sampai selesai.
5. Buka `Face AI Lab` dari Profile.
6. Uji beberapa foto sendiri dan foto orang lain untuk melihat margin similarity.
7. Buka tab `Absensi`.
8. Tekan tombol presensi untuk check-in.
9. Arahkan wajah ke kamera.
10. Jika switch dev kedip aktif, kedipkan mata saat diminta.
11. Pastikan popup check-in berhasil muncul.
12. Lakukan check-out dengan flow yang sama.

Untuk menguji kasus gagal, gunakan wajah berbeda atau foto dengan kondisi yang sengaja buruk. Berdasarkan uji terakhir, wajah asli bisa mencapai sekitar 87% similarity, sedangkan wajah berbeda berada jauh lebih rendah, sekitar 40% pada pengujian manual.

## Catatan Face Recognition

- Face detection memakai Google ML Kit.
- Face embedding memakai MobileFaceNet.
- Input model menggunakan crop wajah `112x112`.
- Output embedding berukuran 192 dimensi.
- Embedding dinormalisasi L2.
- Matching utama memakai cosine similarity.
- Presensi membandingkan query embedding ke semua embedding referensi milik user, lalu mengambil skor tertinggi.
- Threshold presensi saat ini memakai cosine similarity `0.65`.
- Face alignment wajib dijaga konsisten antara enrollment, Face AI Lab, dan presensi.
- Face AI Lab dipakai untuk kalibrasi threshold sebelum liveness final dirapikan.
- Presensi hanya mencocokkan wajah terhadap embedding milik akun yang sedang login.
- Jika SQLite belum punya embedding akun tersebut, aplikasi mengambil backup dari Supabase lalu menyimpannya kembali ke SQLite.

## Dev Switch Liveness

Di Profile tersedia switch:

```text
Dev: Kedip Saat Presensi
```

Jika mati, presensi langsung melakukan face match setelah user menatap kamera.

Jika aktif, presensi meminta user kedip terlebih dahulu sebelum face match. Switch ini dibuat untuk tahap pengembangan dan belum dimaksudkan sebagai konfigurasi production final.

## Platform

Target utama project saat ini adalah Android/native.

Web masih memakai stub untuk fitur kamera dan face recognition, sehingga flow presensi wajah tidak ditujukan untuk browser.

## Dokumentasi Konsep

Penjelasan konsep yang lebih lengkap ada di:

```text
Konsep_Projek.md
```

## Status Saat Ini

Project sudah memiliki alur inti untuk:

- Auth Supabase.
- Enrollment wajah multi-sampel.
- Presensi check-in/check-out dengan verifikasi wajah.
- Face AI Lab untuk debugging dan kalibrasi.
- Penyimpanan embedding lokal dan sync ke Supabase.
- Tracker worklog.
- Kalender.
- Laporan PDF.
- Popup sukses presensi.

Fitur yang belum menjadi flow final:

- Liveness challenge production.
- GPS presensi.
- Face recognition di web.
- Panel admin penuh untuk HR.
