import 'dart:convert';

import 'package:http/http.dart' as http;

class AttendanceScheduleService {
  AttendanceScheduleService._();
  static final AttendanceScheduleService instance =
      AttendanceScheduleService._();

  static const String _baseUrl = String.fromEnvironment(
    'PRESENSIA_BACKEND_URL',
    defaultValue: 'https://apipre.kitapunya.web.id',
  );

  Future<AttendanceScheduleConfig> fetchConfig() async {
    final uri = Uri.parse('$_baseUrl/api/mobile/attendance/schedule-config');
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    final payload = _decode(response);
    return AttendanceScheduleConfig.fromJson(
      payload['data'] as Map<String, dynamic>? ?? {},
    );
  }

  Future<ScheduleValidationResult> validate({
    required String action,
    String? shiftId,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/mobile/attendance/validate-schedule');
    final body = <String, dynamic>{
      'action': action,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
    if (shiftId != null) body['shift_id'] = shiftId;

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    final payload = _decode(response);
    return ScheduleValidationResult.fromJson(
      payload['data'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> _decode(http.Response response) {
    final payload =
        jsonDecode(response.body.isEmpty ? '{}' : response.body)
            as Map<String, dynamic>;
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        payload['success'] == false) {
      throw StateError(
        payload['message'] as String? ?? 'Validasi jadwal gagal.',
      );
    }
    return payload;
  }
}

class AttendanceScheduleConfig {
  const AttendanceScheduleConfig({
    required this.scheduleEnabled,
    required this.scheduleMode,
    required this.requireShiftSelection,
    required this.officeCheckInStart,
    required this.officeCheckInEnd,
    required this.officeLateAfter,
    required this.officeCheckOutStart,
    required this.officeCheckOutEnd,
    required this.shifts,
  });

  final bool scheduleEnabled;
  final String scheduleMode;
  final bool requireShiftSelection;
  final String officeCheckInStart;
  final String officeCheckInEnd;
  final String officeLateAfter;
  final String officeCheckOutStart;
  final String officeCheckOutEnd;
  final List<WorkShift> shifts;

  bool get requiresShift =>
      scheduleEnabled && scheduleMode == 'shift' && requireShiftSelection;

  factory AttendanceScheduleConfig.fromJson(Map<String, dynamic> json) {
    final schedule = json['schedule'] as Map<String, dynamic>? ?? {};
    final shifts = (json['shifts'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((item) => WorkShift.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    return AttendanceScheduleConfig(
      scheduleEnabled: schedule['scheduleEnabled'] == true,
      scheduleMode: schedule['scheduleMode'] as String? ?? 'free',
      requireShiftSelection: schedule['requireShiftSelection'] != false,
      officeCheckInStart: schedule['officeCheckInStart'] as String? ?? '07:30',
      officeCheckInEnd: schedule['officeCheckInEnd'] as String? ?? '08:15',
      officeLateAfter: schedule['officeLateAfter'] as String? ?? '08:00',
      officeCheckOutStart:
          schedule['officeCheckOutStart'] as String? ?? '17:00',
      officeCheckOutEnd: schedule['officeCheckOutEnd'] as String? ?? '18:00',
      shifts: shifts,
    );
  }
}

class WorkShift {
  const WorkShift({
    required this.id,
    required this.name,
    required this.checkInStart,
    required this.checkInEnd,
    required this.lateAfter,
    required this.checkOutStart,
    required this.checkOutEnd,
    required this.crossesMidnight,
  });

  final String id;
  final String name;
  final String checkInStart;
  final String checkInEnd;
  final String lateAfter;
  final String checkOutStart;
  final String checkOutEnd;
  final bool crossesMidnight;

  factory WorkShift.fromJson(Map<String, dynamic> json) => WorkShift(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Shift',
    checkInStart: json['check_in_start'] as String? ?? '07:30',
    checkInEnd: json['check_in_end'] as String? ?? '08:15',
    lateAfter: json['late_after'] as String? ?? '08:00',
    checkOutStart: json['check_out_start'] as String? ?? '17:00',
    checkOutEnd: json['check_out_end'] as String? ?? '18:00',
    crossesMidnight: json['crosses_midnight'] == true,
  );
}

class ScheduleValidationResult {
  const ScheduleValidationResult({
    required this.allowed,
    required this.scheduleMode,
    required this.scheduleStatus,
    required this.lateMinutes,
    required this.requiresCheckoutReason,
    required this.message,
    this.selectedShiftId,
  });

  final bool allowed;
  final String scheduleMode;
  final String scheduleStatus;
  final int lateMinutes;
  final bool requiresCheckoutReason;
  final String message;
  final String? selectedShiftId;

  factory ScheduleValidationResult.fromJson(Map<String, dynamic> json) =>
      ScheduleValidationResult(
        allowed: json['allowed'] != false,
        scheduleMode: json['schedule_mode'] as String? ?? 'free',
        scheduleStatus: json['schedule_status'] as String? ?? 'present',
        lateMinutes: (json['late_minutes'] as num?)?.round() ?? 0,
        requiresCheckoutReason: json['requires_checkout_reason'] == true,
        message: json['message'] as String? ?? '',
        selectedShiftId: json['selected_shift_id'] as String?,
      );
}
