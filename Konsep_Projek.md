# Konsep Project Presensia

Presensia adalah aplikasi mobile employee self-service berbasis Flutter untuk presensi wajah, pencatatan pekerjaan harian, kalender kehadiran, dan laporan performa karyawan.

Dokumen ini menjelaskan konsep produk dan kondisi implementasi project saat ini.

---

## Daftar Isi

- [Latar Belakang](#latar-belakang)
- [Tujuan Produk](#tujuan-produk)
- [Target Pengguna](#target-pengguna)
- [Prinsip Desain Face Recognition](#prinsip-desain-face-recognition)
- [Alur Penggunaan](#alur-penggunaan)
- [Status Pengembangan](#status-pengembangan)
- [Fitur Utama](#fitur-utama)
- [Arsitektur Sistem](#arsitektur-sistem)
- [Face Recognition Pipeline](#face-recognition-pipeline)
- [Flow Enrollment Wajah](#flow-enrollment-wajah)
- [Flow Presensi Wajah](#flow-presensi-wajah)
- [Face AI Lab](#face-ai-lab)
- [Struktur Folder](#struktur-folder)
- [Setup Singkat](#setup-singkat)
- [Catatan Pengembangan Lanjutan](#catatan-pengembangan-lanjutan)

---

## Latar Belakang

Presensi karyawan dengan metode manual, kartu, PIN, atau tanda tangan mudah dimanipulasi dan sulit dikaitkan langsung dengan aktivitas kerja harian. Presensia dibuat untuk menggabungkan presensi, pekerjaan harian, kalender, dan laporan dalam satu aplikasi.

Masalah yang ingin diselesaikan:

- Mengurangi risiko titip absen.
- Membuat check-in dan check-out lebih cepat melalui verifikasi wajah.
- Menghubungkan data presensi dengan worklog harian.
- Memudahkan karyawan melihat status kerja hari ini.
- Memudahkan HR/admin membaca rekap kehadiran dan performa.

---

## Tujuan Produk

1. **Presensi lebih valid**
   Karyawan melakukan check-in dan check-out melalui pencocokan wajah.

2. **Worklog terpusat**
   Pekerjaan harian dicatat dalam Tracker dan bisa dikaitkan dengan project.

3. **Data mudah dipantau**
   Kalender dan laporan membantu melihat pola hadir, izin, libur, absen, jam kerja, dan produktivitas.

4. **Pengalaman pengguna jelas**
   Aplikasi memberi status visual ketika kamera siap, sedang menganalisis wajah, sukses, atau gagal.

---

## Target Pengguna

**Karyawan**

- Check-in dan check-out.
- Mendaftarkan wajah.
- Mengisi worklog atau timer pekerjaan.
- Melihat kalender kehadiran.
- Melihat laporan pribadi.

**Admin / HR**

- Melihat dan mengelola data kehadiran.
- Meninjau worklog dan laporan performa.
- Mengatur data kalender kerja, libur, izin, dan laporan.

---

## Prinsip Desain Face Recognition

Face recognition di project ini dibagi menjadi dua tugas yang berbeda:

- **Face detection:** Google ML Kit mencari lokasi wajah, landmark mata, pose Euler, dan sinyal kualitas dasar.
- **Face recognition:** MobileFaceNet mengubah crop wajah yang sudah dirapikan menjadi embedding 192 dimensi.

Keputusan desain saat ini:

- Model recognition utama hanya **MobileFaceNet**.
- Semua sumber gambar harus melewati preprocessing yang sama: upright image, ML Kit, face alignment, crop, resize `112x112`, normalisasi piksel, dan L2 normalization.
- Matching memakai **cosine similarity**, bukan Euclidean sebagai keputusan utama.
- Enrollment menyimpan beberapa embedding referensi agar presensi lebih stabil.
- Presensi mengambil skor paling tinggi dari semua embedding referensi user.
- Face AI Lab dipakai untuk menguji akurasi sebelum liveness production difinalkan.

---

## Alur Penggunaan

### 1. Pendaftaran Wajah

```
Buka Daftarkan Wajah
        |
        v
Kamera depan aktif
        |
        v
User mengikuti tahap frontal, kiri ringan, dan kanan ringan
        |
        v
Sistem mengambil total 9 sampel valid
        |
        v
Setiap sampel melewati ML Kit + quality gate
        |
        v
Face alignment berdasarkan landmark mata
        |
        v
Crop wajah -> resize 112x112
        |
        v
MobileFaceNet menghasilkan embedding 192 dimensi
        |
        v
Sistem menyimpan 6 embedding referensi
```

Catatan penting:

- Enrollment tidak lagi memakai 1 foto.
- Enrollment mengambil 3 sampel frontal, 3 sampel kiri ringan, dan 3 sampel kanan ringan.
- Embedding akhir disimpan sebagai 6 referensi: average dan best untuk tiap kelompok pose.
- Data wajah disimpan melalui `EmbeddingSyncService.saveEmbeddings`.
- Jika data wajah tidak ada di SQLite tetapi ada di Supabase, aplikasi dapat mengambil backup tersebut dan menyimpannya kembali ke SQLite.

### 2. Check-In

```
Buka tab Absensi
        |
        v
Tekan tombol presensi
        |
        v
Kamera mulai verifikasi
        |
        v
Jika switch dev aktif, user diminta kedip
        |
        v
User menatap lurus ke kamera
        |
        v
Query embedding dibuat dari frame terbaik
        |
        v
Query dibandingkan ke 6 embedding referensi user
        |
        +-- similarity >= 0.65 --> Check-in berhasil + popup semangat kerja
        |
        +-- similarity < 0.65 --> Presensi gagal, coba ulangi
```

### 3. Check-Out

Flow check-out memakai verifikasi wajah yang sama. Setelah berhasil, aplikasi menampilkan popup berisi pesan terima kasih dan selamat pulang.

```
Tekan tombol presensi saat sudah check-in
        |
        v
Konfirmasi check-out
        |
        v
Scan dan cocokkan wajah
        |
        +-- cocok --> Check-out sukses + popup selamat pulang
        |
        +-- tidak cocok --> Presensi gagal, coba ulangi
```

### 4. Tracker Harian

Karyawan dapat mencatat pekerjaan berdasarkan project. Tracker mendukung timer aktif dan input manual. Data worklog digunakan kembali di kalender dan laporan.

### 5. Kalender dan Laporan

Kalender menampilkan data presensi, izin/libur, dan worklog per tanggal. Laporan menampilkan ringkasan performa dan dapat diekspor ke PDF.

---

## Status Pengembangan

| Area | Status | Keterangan |
|---|---|---|
| UI utama aplikasi | Selesai tahap inti | Home, Tracker, Absensi, Kalender, Laporan, Profil, dan navigasi utama tersedia |
| Auth Supabase | Selesai | Login, register, reset password, dan session terhubung ke Supabase |
| Enrollment wajah | Selesai tahap inti | 9 sampel valid, 3 pose ringan, 6 embedding referensi |
| Presensi wajah | Selesai tahap inti | Check-in/check-out memakai kamera, ML Kit, MobileFaceNet, cosine similarity |
| Face AI Lab | Selesai tahap dev | Uji foto galeri/kamera terhadap embedding enrollment |
| Dev switch kedip | Selesai tahap dev | Bisa aktif/nonaktifkan kedip presensi dari Profile |
| SQLite embedding | Selesai | Cache embedding lokal melalui `EmbeddingDb` |
| Sync embedding Supabase | Selesai tahap inti | Embedding disimpan/sync melalui service embedding |
| Tracker/worklog | Selesai tahap inti | Project, timer, input manual, edit/delete worklog |
| Kalender | Selesai tahap inti | Presensi, worklog, izin/libur, dan marker tanggal |
| Laporan PDF | Selesai tahap inti | Generate dan share PDF memakai `pdf` dan `printing` |
| Notifikasi lokal | Ada | Reminder check-in/check-out dan kalender |
| GPS presensi | Belum aktif | Belum ada pencatatan koordinat GPS pada flow presensi saat ini |
| Liveness production | Belum final | Baru ada switch dev untuk kedip; challenge-response final belum dikunci |
| Web support kamera | Stub | Kamera/ML Kit diarahkan untuk Android/native; web menampilkan pesan tidak tersedia |

---

## Fitur Utama

### 1. Presensi Wajah

Presensi dilakukan melalui tombol, bukan otomatis dari live preview.

Karakteristik saat ini:

- Kamera aktif di layar Absensi.
- Layar presensi dibuat fokus ke kamera.
- User menekan tombol presensi untuk memulai scan.
- Jika dev switch kedip aktif, sistem meminta kedip dulu.
- Query embedding dibandingkan ke 6 embedding referensi milik user.
- Skor MAX dipakai sebagai keputusan akhir.
- Jika cocok, presensi disimpan dan popup sukses muncul.
- Presensi tetap membutuhkan koneksi internet untuk menyimpan check-in/check-out.

### 2. Enrollment Wajah Multi-Sampel

Enrollment dibuat lebih kuat dengan 9 sampel:

- 3 frontal.
- 3 kiri ringan.
- 3 kanan ringan.

Setiap sampel yang diterima harus melewati quality gate dasar, lalu diproses dengan face alignment dan MobileFaceNet.

### 3. Face AI Lab

Face AI Lab membantu melihat apakah pipeline recognition sudah sehat sebelum dipakai di presensi production. Lab memakai data enrollment user saat ini sebagai target dan membandingkannya dengan foto uji dari galeri atau kamera.

### 4. Tracker Project dan Worklog

Tracker digunakan untuk:

- Membuat project.
- Memilih project aktif.
- Menjalankan timer pekerjaan.
- Menambah worklog manual.
- Mengedit dan menghapus worklog.

### 5. Kalender Kehadiran

Kalender menampilkan:

- Hari hadir.
- Hari tidak hadir.
- Izin/cuti.
- Libur.
- Worklog pada tanggal tertentu.
- Input manual aktivitas/presensi dari kalender.

### 6. Laporan Performa

Laporan memakai data presensi dan worklog untuk membuat ringkasan:

- Total hari hadir.
- Jam kerja.
- Keterlambatan.
- Statistik worklog.
- Export PDF.

### 7. Profil dan Pengaturan Wajah

Profil menampilkan status data wajah. User dapat:

- Daftarkan ulang wajah.
- Membuka Face AI Lab.
- Mengaktifkan atau menonaktifkan dev switch kedip presensi.

---

## Arsitektur Sistem

```
Flutter App
  |
  +-- Presentation
  |     +-- Home
  |     +-- Tracker
  |     +-- Attendance
  |     +-- Calendar
  |     +-- Report
  |     +-- Profile
  |
  +-- Shared Services
  |     +-- AuthService
  |     +-- AttendanceService
  |     +-- WorklogService
  |     +-- ProjectService
  |     +-- FaceRecognitionService
  |     +-- EmbeddingSyncService
  |     +-- AttendanceDevSettings
  |     +-- NotificationService
  |
  +-- Storage
        +-- SQLite: cache embedding wajah
        +-- Supabase: auth, presensi, worklog, project, profile, embedding backup
```

| Komponen | Teknologi |
|---|---|
| Framework | Flutter / Dart |
| Auth dan cloud database | Supabase |
| Local database | SQLite via `sqflite` |
| Kamera | `camera` |
| Face detection | `google_mlkit_face_detection` |
| Face recognition | MobileFaceNet via `tflite_flutter` |
| Image processing | `image` |
| Image picker | `image_picker` |
| Kalender | `table_calendar` |
| Grafik laporan | `fl_chart` |
| PDF export | `pdf`, `printing` |
| Notifikasi | `flutter_local_notifications`, `timezone` |
| Kecerahan layar | `screen_brightness` |

---

## Face Recognition Pipeline

Pipeline saat ini:

```
Foto / frame kamera
        |
        v
Normalisasi orientasi gambar
        |
        v
ML Kit Face Detection
        |
        v
Validasi 1 wajah, ukuran wajah, pose, dan kualitas dasar
        |
        v
Ambil landmark mata
        |
        v
Face alignment agar mata sejajar horizontal
        |
        v
Crop wajah
        |
        v
Resize ke 112x112 RGB
        |
        v
Normalisasi piksel sesuai input MobileFaceNet
        |
        v
MobileFaceNet TFLite
        |
        v
Embedding 192 dimensi
        |
        v
L2 normalization
        |
        v
Cosine similarity ke embedding referensi
        |
        v
similarity >= 0.65 ? cocok : tidak cocok
```

Detail teknis:

- Model utama: `assets/models/mobilefacenet.tflite`
- Input model: `112x112x3`
- Output embedding: 192 dimensi
- Metode pencocokan: cosine similarity
- Threshold presensi saat ini: `0.65`
- Embedding referensi: 6 per user
- Skor keputusan: nilai similarity tertinggi dari semua embedding referensi user

Uji manual terakhir menunjukkan wajah asli bisa mencapai sekitar 87% similarity setelah pipeline alignment dan referensi embedding dirapikan, sedangkan wajah berbeda berada jauh lebih rendah pada pengujian manual.

---

## Flow Enrollment Wajah

```
User membuka enrollment
        |
        v
Kamera depan aktif
        |
        v
Sistem meminta pose frontal
        |
        v
Ambil 3 sampel valid
        |
        v
Sistem meminta pose kiri ringan
        |
        v
Ambil 3 sampel valid
        |
        v
Sistem meminta pose kanan ringan
        |
        v
Ambil 3 sampel valid
        |
        v
Buat embedding tiap sampel
        |
        v
Buat avg dan best untuk tiap pose
        |
        v
Simpan 6 embedding referensi
```

Alasan memakai 6 embedding:

- Rata-rata embedding membuat representasi lebih stabil.
- Best embedding menjaga skor tetap tinggi untuk pose yang benar-benar bersih.
- Pose kiri/kanan ringan membantu ketika wajah presensi tidak 100% frontal.
- Presensi mengambil MAX score sehingga query bisa cocok ke referensi paling dekat.

---

## Flow Presensi Wajah

Presensi memakai data wajah dari enrollment, bukan data manual dari Face AI Lab.

```
Tekan tombol presensi
        |
        v
Cek koneksi internet
        |
        v
Mulai scan kamera
        |
        v
Jika dev switch aktif: cek kedip
        |
        v
Ambil frame wajah stabil
        |
        v
Query embedding dibuat
        |
        v
Compare query ke 6 referensi user
        |
        v
Ambil similarity tertinggi
        |
        +-- >= 0.65: simpan attendance
        |
        +-- < 0.65: tampilkan gagal
```

Catatan:

- Check-in menyimpan source `face`.
- Check-out mengikuti record presensi hari ini.
- Popup sukses berbeda antara check-in dan check-out.
- Error seperti internet mati, wajah tidak cocok, atau timeout ditampilkan sebagai snackbar.

---

## Face AI Lab

Face AI Lab adalah alat internal dev untuk menguji recognition tanpa harus menjalankan flow presensi penuh.

Fungsi lab:

- Mengambil target dari embedding enrollment user yang sedang login.
- Menguji foto dari galeri atau kamera.
- Menampilkan similarity dan threshold pass/fail.
- Menampilkan quality score, pose Euler, ukuran wajah, inference time, distance, dan best target.
- Membantu membedakan masalah enrollment buruk, foto uji buruk, atau pipeline preprocessing.

Threshold yang ditampilkan:

- `0.65` longgar / target presensi saat ini.
- `0.70` sedang.
- `0.75` ketat.

Lab tidak menggantikan presensi dan tidak menyimpan kehadiran.

---

## Struktur Folder

Struktur utama project saat ini:

```
face_recognizer/
|-- assets/
|   |-- models/
|       |-- mobilefacenet.tflite
|-- lib/
|   |-- main.dart
|   |-- features/
|   |   |-- auth/
|   |   |-- home/
|   |   |-- main_nav/
|   |   |-- attendance/
|   |   |-- enrollment/
|   |   |-- tracker/
|   |   |-- calendar/
|   |   |-- report/
|   |   |-- profile/
|   |-- shared/
|       |-- database/
|       |-- models/
|       |-- providers/
|       |-- services/
|       |   |-- face/
|       |-- store/
|       |-- theme/
|-- supabase/
|-- test/
|-- pubspec.yaml
```

File penting terkait wajah:

| File | Fungsi |
|---|---|
| `lib/features/enrollment/presentation/enrollment_screen_native.dart` | Pendaftaran wajah multi-sampel |
| `lib/features/attendance/presentation/attendance_screen.dart` | Flow presensi, face match, popup sukses |
| `lib/features/attendance/presentation/camera_face_view_native.dart` | Kamera, deteksi wajah, liveness kedip dev, overlay frame |
| `lib/features/profile/presentation/face_ai_lab_screen_native.dart` | Lab pengujian similarity |
| `lib/shared/services/face/face_recognition_service_native.dart` | MobileFaceNet, alignment, crop, embedding, matching |
| `lib/shared/services/face/embedding_sync_service.dart` | Simpan/sync embedding |
| `lib/shared/database/embedding_db.dart` | Cache SQLite embedding |
| `lib/shared/services/attendance_dev_settings.dart` | Switch dev untuk kedip presensi |

---

## Setup Singkat

1. Install dependency:

```bash
flutter pub get
```

2. Pastikan model tersedia:

```text
assets/models/mobilefacenet.tflite
```

3. Pastikan asset terdaftar di `pubspec.yaml`:

```yaml
flutter:
  assets:
    - public/
    - assets/models/mobilefacenet.tflite
```

4. Jalankan aplikasi:

```bash
flutter run
```

5. Urutan tes yang disarankan:

- Login/register user.
- Buka Profile.
- Daftarkan wajah sampai selesai.
- Buka Face AI Lab.
- Uji wajah sendiri dan wajah orang lain.
- Buka tab Absensi.
- Coba check-in dan check-out.
- Aktifkan atau matikan `Dev: Kedip Saat Presensi` dari Profile untuk membandingkan flow.

---

## Catatan Pengembangan Lanjutan

Beberapa hal yang masih bisa dikembangkan:

- Membuat liveness challenge production dengan instruksi acak, misalnya kedip, senyum, atau tengok ringan.
- Menambahkan audit log presensi gagal tanpa menyimpan foto wajah.
- Kalibrasi threshold dengan dataset 10-30 user lokal.
- Menambahkan GPS/geofence jika presensi perlu validasi lokasi.
- Menambahkan role admin yang lebih tegas untuk enrollment karyawan lain.
- Menambahkan pengujian integrasi kamera pada perangkat Android.
