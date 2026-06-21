import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/app_models.dart';

/// Local SQLite cache for session data (profile, settings, attendance,
/// worklogs, reminders of the current month).
///
/// Purpose: When the app re-opens, data is loaded from this cache first
/// (instant), then Supabase sync runs in background. Once Supabase data
/// is loaded successfully, the cache is cleared.
///
/// This is a SEPARATE database from face_embeddings.db — face recognition
/// data is never touched by this class.
class SessionCacheDb {
  static final SessionCacheDb instance = SessionCacheDb._();
  SessionCacheDb._();

  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = join(dir, 'session_cache.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE cached_profile (
            employee_id TEXT PRIMARY KEY,
            data        TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_settings (
            employee_id TEXT PRIMARY KEY,
            data        TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_attendance (
            date_key TEXT PRIMARY KEY,
            data    TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_worklogs (
            date_key TEXT PRIMARY KEY,
            data    TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_reminders (
            date_key TEXT PRIMARY KEY,
            data    TEXT NOT NULL
          )
        ''');
      },
    );
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  /// Persist the full AppStore state into the session cache.
  Future<void> saveAll({
    required EmployeeProfile profile,
    required WorkScheduleSettings settings,
    required Map<String, AttendanceRecord> attendance,
    required Map<String, List<WorklogEntry>> worklogs,
    required Map<String, List<ReminderEvent>> reminders,
  }) async {
    final d = await db;
    final batch = d.batch();

    // Profile — 1 row
    batch.delete('cached_profile');
    batch.insert('cached_profile', {
      'employee_id': profile.id,
      'data': jsonEncode(profile.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Settings — 1 row
    batch.delete('cached_settings');
    batch.insert('cached_settings', {
      'employee_id': profile.id,
      'data': jsonEncode(settings.toJson(employeeId: profile.id)),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Attendance — per date_key
    batch.delete('cached_attendance');
    for (final entry in attendance.entries) {
      batch.insert('cached_attendance', {
        'date_key': entry.key,
        'data': jsonEncode(entry.value.toJson(employeeId: profile.id)),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // Worklogs — per date_key (list of entries)
    batch.delete('cached_worklogs');
    for (final entry in worklogs.entries) {
      batch.insert('cached_worklogs', {
        'date_key': entry.key,
        'data': jsonEncode(
          entry.value.map((e) => e.toJson(employeeId: profile.id)).toList(),
        ),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // Reminders — per date_key (list of events)
    batch.delete('cached_reminders');
    for (final entry in reminders.entries) {
      batch.insert('cached_reminders', {
        'date_key': entry.key,
        'data': jsonEncode(
          entry.value.map((e) => e.toJson(employeeId: profile.id)).toList(),
        ),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  // ── Load ──────────────────────────────────────────────────────────────────

  /// Load all cached data. Returns null for fields that have no cache.
  Future<({
    EmployeeProfile? profile,
    WorkScheduleSettings? settings,
    Map<String, AttendanceRecord> attendance,
    Map<String, List<WorklogEntry>> worklogs,
    Map<String, List<ReminderEvent>> reminders,
  })> loadAll() async {
    final d = await db;

    // Profile
    final profileRows = await d.query('cached_profile', limit: 1);
    EmployeeProfile? profile;
    if (profileRows.isNotEmpty) {
      try {
        profile = EmployeeProfile.fromJson(
          jsonDecode(profileRows.first['data'] as String)
              as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    // Settings
    final settingsRows = await d.query('cached_settings', limit: 1);
    WorkScheduleSettings? settings;
    if (settingsRows.isNotEmpty && profile != null) {
      try {
        settings = WorkScheduleSettings.fromJson(
          jsonDecode(settingsRows.first['data'] as String)
              as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    // Attendance
    final attRows = await d.query('cached_attendance');
    final attendance = <String, AttendanceRecord>{};
    for (final row in attRows) {
      try {
        final record = AttendanceRecord.fromJson(
          jsonDecode(row['data'] as String) as Map<String, dynamic>,
        );
        final key = row['date_key'] as String;
        attendance[key] = record;
      } catch (_) {}
    }

    // Worklogs
    final wlRows = await d.query('cached_worklogs');
    final worklogs = <String, List<WorklogEntry>>{};
    for (final row in wlRows) {
      try {
        final list = (jsonDecode(row['data'] as String) as List)
            .map((e) => WorklogEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        worklogs[row['date_key'] as String] = list;
      } catch (_) {}
    }

    // Reminders
    final remRows = await d.query('cached_reminders');
    final reminders = <String, List<ReminderEvent>>{};
    for (final row in remRows) {
      try {
        final list = (jsonDecode(row['data'] as String) as List)
            .map((e) => ReminderEvent.fromJson(e as Map<String, dynamic>))
            .toList();
        reminders[row['date_key'] as String] = list;
      } catch (_) {}
    }

    return (
      profile: profile,
      settings: settings,
      attendance: attendance,
      worklogs: worklogs,
      reminders: reminders,
    );
  }

  /// Check if any cached data exists.
  Future<bool> hasCache() async {
    final d = await db;
    final profileRows = await d.query('cached_profile', limit: 1);
    return profileRows.isNotEmpty;
  }

  // ── Clear ─────────────────────────────────────────────────────────────────

  /// Delete all cached session data.
  Future<void> clear() async {
    final d = await db;
    final batch = d.batch();
    batch.delete('cached_profile');
    batch.delete('cached_settings');
    batch.delete('cached_attendance');
    batch.delete('cached_worklogs');
    batch.delete('cached_reminders');
    await batch.commit(noResult: true);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
