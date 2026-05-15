import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/app_models.dart';
import 'supabase_client.dart';

class AttendanceService {
  static final AttendanceService instance = AttendanceService._();
  AttendanceService._();

  SupabaseClient get _db => SupabaseClientService.client;
  static const _uuid = Uuid();

  Future<AttendanceRecord?> fetchTodayRecord(String employeeId) async {
    final today = _dateStr(DateTime.now());
    final data = await _db
        .from('attendance_records')
        .select()
        .eq('employee_id', employeeId)
        .eq('date', today)
        .maybeSingle();
    return data != null ? AttendanceRecord.fromJson(data) : null;
  }

  Future<List<AttendanceRecord>> fetchMonthRecords(
    String employeeId,
    int year,
    int month,
  ) async {
    final from = '$year-${month.toString().padLeft(2, '0')}-01';
    final lastDay = DateTime(year, month + 1, 0).day;
    final to =
        '$year-${month.toString().padLeft(2, '0')}-${lastDay.toString().padLeft(2, '0')}';

    final data = await _db
        .from('attendance_records')
        .select()
        .eq('employee_id', employeeId)
        .gte('date', from)
        .lte('date', to)
        .order('date');

    return (data as List).map((r) => AttendanceRecord.fromJson(r)).toList();
  }

  Future<List<AttendanceRecord>> fetchWeekRecords(
    String employeeId,
    DateTime anyDayInWeek,
  ) async {
    final monday = anyDayInWeek.subtract(
      Duration(days: anyDayInWeek.weekday - 1),
    );
    final sunday = monday.add(const Duration(days: 6));

    final data = await _db
        .from('attendance_records')
        .select()
        .eq('employee_id', employeeId)
        .gte('date', _dateStr(monday))
        .lte('date', _dateStr(sunday))
        .order('date');

    return (data as List).map((r) => AttendanceRecord.fromJson(r)).toList();
  }

  Future<List<AttendanceRecord>> fetchRecordsInRange(
    String employeeId,
    DateTime from,
    DateTime to,
  ) async {
    final data = await _db
        .from('attendance_records')
        .select()
        .eq('employee_id', employeeId)
        .gte('date', _dateStr(from))
        .lte('date', _dateStr(to))
        .order('date');

    return (data as List).map((r) => AttendanceRecord.fromJson(r)).toList();
  }

  Future<AttendanceRecord> checkIn(
    String employeeId, {
    AttendanceSource source = AttendanceSource.face,
    String? note,
  }) async {
    final now = DateTime.now();
    final record = AttendanceRecord(
      id: _uuid.v4(),
      date: DateTime(now.year, now.month, now.day),
      source: source,
      status: AttendanceStatus.present,
      checkIn: TimeOfDay(hour: now.hour, minute: now.minute),
      note: note,
    );

    final payload = record.toJson(employeeId: employeeId);
    // Use DB server time for check_in to avoid clock drift
    payload['check_in'] = now.toUtc().toIso8601String();

    final inserted = await _db
        .from('attendance_records')
        .upsert(payload, onConflict: 'employee_id,date')
        .select()
        .single();
    return AttendanceRecord.fromJson(inserted);
  }

  Future<AttendanceRecord> checkOut(String employeeId) async {
    final now = DateTime.now();
    final today = _dateStr(now);

    final updated = await _db
        .from('attendance_records')
        .update({
          'check_out': now.toUtc().toIso8601String(),
          'updated_at': now.toUtc().toIso8601String(),
        })
        .eq('employee_id', employeeId)
        .eq('date', today)
        .select()
        .single();
    return AttendanceRecord.fromJson(updated);
  }

  Future<AttendanceRecord> checkInWithFaceNonce(
    String employeeId, {
    AttendanceSource source = AttendanceSource.face,
    String? note,
  }) async {
    final now = DateTime.now();
    final nonce = _uuid.v4();

    final data = await _db.rpc(
      'check_in_with_nonce',
      params: {
        'p_employee_id': employeeId,
        'p_nonce': nonce,
        'p_timestamp': now.toUtc().toIso8601String(),
        'p_note': note,
      },
    );
    return AttendanceRecord.fromJson((data as List).first as Map<String, dynamic>);
  }

  Future<AttendanceRecord> checkOutWithFaceNonce(String employeeId) async {
    final now = DateTime.now();
    final nonce = _uuid.v4();

    final data = await _db.rpc(
      'check_out_with_nonce',
      params: {
        'p_employee_id': employeeId,
        'p_nonce': nonce,
        'p_timestamp': now.toUtc().toIso8601String(),
      },
    );
    return AttendanceRecord.fromJson((data as List).first as Map<String, dynamic>);
  }

  /// Full upsert — used for manual entry and calendar edits.
  Future<AttendanceRecord> upsertRecord(
    AttendanceRecord record,
    String employeeId,
  ) async {
    final data = record.toJson(employeeId: employeeId)
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String();

    final result = await _db
        .from('attendance_records')
        .upsert(data, onConflict: 'employee_id,date')
        .select()
        .single();
    return AttendanceRecord.fromJson(result);
  }

  Future<void> deleteRecord(String employeeId, DateTime date) async {
    await _db
        .from('attendance_records')
        .delete()
        .eq('employee_id', employeeId)
        .eq('date', _dateStr(date));
  }

  static String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
