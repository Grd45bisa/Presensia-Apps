import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_client.dart';

/// Merepresentasikan satu hari libur di tabel `national_holidays`.
class NationalHoliday {
  final String id;
  final DateTime date;
  final String name;
  final String? description;
  final bool isNational;

  const NationalHoliday({
    required this.id,
    required this.date,
    required this.name,
    this.description,
    required this.isNational,
  });

  factory NationalHoliday.fromJson(Map<String, dynamic> json) {
    return NationalHoliday(
      id: json['id'] as String,
      date: DateTime.parse(json['holiday_date'] as String),
      name: json['name'] as String? ?? 'Libur',
      description: json['description'] as String?,
      isNational: (json['is_national'] as bool?) ?? true,
    );
  }
}

/// Membaca kalender libur dari tabel `national_holidays` dan menyimpannya
/// secara in-memory sebagai kumpulan "YYYY-MM-DD" supaya cepat dicek saat
/// menjadwalkan pengingat presensi.
///
/// Daftar libur di-refresh saat login dan setiap kali tabel berubah via
/// Realtime (dikelola oleh [RealtimeSyncService]).
class HolidayService {
  static final HolidayService instance = HolidayService._();
  HolidayService._();

  SupabaseClient get _db => SupabaseClientService.client;

  final Set<String> _holidayKeys = {};
  final Map<String, NationalHoliday> _byKey = {};
  bool _loaded = false;

  /// Kumpulan tanggal libur dalam format "YYYY-MM-DD" (waktu lokal).
  Set<String> get holidayKeys => Set.unmodifiable(_holidayKeys);

  /// Libur pada [day] jika ada, null jika bukan hari libur.
  NationalHoliday? holidayOf(DateTime day) => _byKey[_dateKey(day)];

  bool isHoliday(DateTime day) => _holidayKeys.contains(_dateKey(day));

  bool get isLoaded => _loaded;

  /// Memuat libur untuk rentang [monthsAround] bulan di sekitar hari ini.
  Future<void> load({int monthsAround = 1}) async {
    try {
      final now = DateTime.now();
      final from = DateTime(now.year, now.month - monthsAround, 1);
      final to = DateTime(now.year, now.month + monthsAround + 1, 0);

      final data = await _db
          .from('national_holidays')
          .select()
          .gte('holiday_date', _dateKey(from))
          .lte('holiday_date', _dateKey(to))
          .order('holiday_date');

      _holidayKeys.clear();
      _byKey.clear();
      for (final row in data as List) {
        final holiday = NationalHoliday.fromJson(
          Map<String, dynamic>.from(row as Map),
        );
        final key = _dateKey(holiday.date);
        _holidayKeys.add(key);
        _byKey[key] = holiday;
      }
      _loaded = true;
    } catch (_) {
      // Jangan crash app kalau tabel belum ada / jaringan gagal.
      _loaded = true;
    }
  }

  /// Hapus cache (dipanggil saat logout).
  void clear() {
    _holidayKeys.clear();
    _byKey.clear();
    _loaded = false;
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
