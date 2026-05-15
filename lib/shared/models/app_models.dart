import 'package:flutter/material.dart';

// ─── ENUMS ───────────────────────────────────────────────────────────────────

enum AttendanceSource {
  face,
  manual;

  static AttendanceSource fromString(String v) =>
      AttendanceSource.values.firstWhere((e) => e.name == v);
}

enum AttendanceStatus {
  present,
  leave,
  sick,
  training,
  meeting,
  holiday,
  otherException;

  static AttendanceStatus fromString(String v) =>
      AttendanceStatus.values.firstWhere((e) => e.name == v);
}

enum DayDisplayState {
  presentWorkday,
  workedOnOffDay,
  offDay,
  manualException,
  missingAttendance,
  futureDay,
}

// ─── ATTENDANCE RECORD ───────────────────────────────────────────────────────

class AttendanceRecord {
  final String id;
  final DateTime date;
  final AttendanceSource source;
  final AttendanceStatus status;
  final TimeOfDay? checkIn;
  final TimeOfDay? checkOut;
  final String? note;
  final String? nonce;
  final DateTime? nonceUsedAt;

  const AttendanceRecord({
    required this.id,
    required this.date,
    required this.source,
    required this.status,
    this.checkIn,
    this.checkOut,
    this.note,
    this.nonce,
    this.nonceUsedAt,
  });

  AttendanceRecord copyWith({
    String? id,
    DateTime? date,
    AttendanceSource? source,
    AttendanceStatus? status,
    TimeOfDay? checkIn,
    TimeOfDay? checkOut,
    String? note,
    String? nonce,
    DateTime? nonceUsedAt,
    bool clearCheckOut = false,
  }) => AttendanceRecord(
    id: id ?? this.id,
    date: date ?? this.date,
    source: source ?? this.source,
    status: status ?? this.status,
    checkIn: checkIn ?? this.checkIn,
    checkOut: clearCheckOut ? null : (checkOut ?? this.checkOut),
    note: note ?? this.note,
    nonce: nonce ?? this.nonce,
    nonceUsedAt: nonceUsedAt ?? this.nonceUsedAt,
  );

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    final checkInTs = json['check_in'] != null
        ? DateTime.parse(json['check_in'])
        : null;
    final checkOutTs = json['check_out'] != null
        ? DateTime.parse(json['check_out'])
        : null;

    return AttendanceRecord(
      id: json['id'] as String,
      date: DateTime.parse(json['date'] as String),
      source: AttendanceSource.fromString(json['source'] as String),
      status: AttendanceStatus.fromString(json['status'] as String),
      checkIn: checkInTs != null
          ? TimeOfDay(
              hour: checkInTs.toLocal().hour,
              minute: checkInTs.toLocal().minute,
            )
          : null,
      checkOut: checkOutTs != null
          ? TimeOfDay(
              hour: checkOutTs.toLocal().hour,
              minute: checkOutTs.toLocal().minute,
            )
          : null,
      note: json['note'] as String?,
      nonce: json['nonce'] as String?,
      nonceUsedAt: json['nonce_used_at'] != null
          ? DateTime.parse(json['nonce_used_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson({required String employeeId}) {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    return {
      'id': id,
      'employee_id': employeeId,
      'date': dateStr,
      'source': source.name,
      'status': status.name,
      'check_in': checkIn != null
          ? _todayAt(checkIn!).toUtc().toIso8601String()
          : null,
      'check_out': checkOut != null
          ? _todayAt(checkOut!).toUtc().toIso8601String()
          : null,
      'note': note,
      'nonce': nonce,
      'nonce_used_at': nonceUsedAt?.toUtc().toIso8601String(),
    };
  }

  DateTime _todayAt(TimeOfDay t) =>
      DateTime(date.year, date.month, date.day, t.hour, t.minute);
}

// ─── WORKLOG ENTRY ───────────────────────────────────────────────────────────

class WorklogEntry {
  final String id;
  final DateTime date;
  final String taskName;
  final String projectName;
  final Color projectColor;
  final TimeOfDay? startTime;
  final TimeOfDay? endTime;
  final String duration;

  const WorklogEntry({
    required this.id,
    required this.date,
    required this.taskName,
    required this.projectName,
    required this.projectColor,
    this.startTime,
    this.endTime,
    required this.duration,
  });

  factory WorklogEntry.fromJson(Map<String, dynamic> json) {
    final startTs = json['start_time'] != null
        ? DateTime.parse(json['start_time'])
        : null;
    final endTs = json['end_time'] != null
        ? DateTime.parse(json['end_time'])
        : null;

    final startLocal = startTs?.toLocal();
    final endLocal = endTs?.toLocal();

    final startTod = startLocal != null
        ? TimeOfDay(hour: startLocal.hour, minute: startLocal.minute)
        : null;
    final endTod = endLocal != null
        ? TimeOfDay(hour: endLocal.hour, minute: endLocal.minute)
        : null;

    return WorklogEntry(
      id: json['id'] as String,
      date: DateTime.parse(json['date'] as String),
      taskName: json['task_name'] as String,
      projectName: json['project_name'] as String,
      projectColor: _colorFromHex(json['project_color'] as String),
      startTime: startTod,
      endTime: endTod,
      duration: _calcDuration(startTod, endTod),
    );
  }

  Map<String, dynamic> toJson({required String employeeId}) {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    return {
      'id': id,
      'employee_id': employeeId,
      'date': dateStr,
      'task_name': taskName,
      'project_name': projectName,
      'project_color': _colorToHex(projectColor),
      'start_time': startTime != null
          ? DateTime(
              date.year,
              date.month,
              date.day,
              startTime!.hour,
              startTime!.minute,
            ).toUtc().toIso8601String()
          : null,
      'end_time': endTime != null
          ? DateTime(
              date.year,
              date.month,
              date.day,
              endTime!.hour,
              endTime!.minute,
            ).toUtc().toIso8601String()
          : null,
    };
  }

  static String _colorToHex(Color c) =>
      '#${c.r.round().toRadixString(16).padLeft(2, '0')}${c.g.round().toRadixString(16).padLeft(2, '0')}${c.b.round().toRadixString(16).padLeft(2, '0')}';

  static Color _colorFromHex(String hex) {
    final clean = hex.replaceFirst('#', '');
    return Color(int.parse('FF$clean', radix: 16));
  }

  static String _calcDuration(TimeOfDay? start, TimeOfDay? end) {
    if (start == null || end == null) return '-';
    final startMin = start.hour * 60 + start.minute;
    final endMin = end.hour * 60 + end.minute;
    var diff = endMin - startMin;
    if (diff < 0) diff += 24 * 60;
    if (diff <= 0) return '-';
    final h = diff ~/ 60;
    final m = diff % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}j';
    return '${h}j ${m}m';
  }
}

// ─── REMINDER EVENT ──────────────────────────────────────────────────────────

class ReminderEvent {
  final String id;
  final String title;
  final String? description;
  final String? location;
  final DateTime startDateTime;
  final DateTime? endDateTime;
  final bool isAllDay;
  final List<int> reminderOffsetsInMinutes;
  final List<int> notificationIds;

  const ReminderEvent({
    required this.id,
    required this.title,
    this.description,
    this.location,
    required this.startDateTime,
    this.endDateTime,
    this.isAllDay = false,
    this.reminderOffsetsInMinutes = const [15, 5],
    this.notificationIds = const [],
  });

  ReminderEvent copyWith({
    String? id,
    String? title,
    String? description,
    String? location,
    DateTime? startDateTime,
    DateTime? endDateTime,
    bool? isAllDay,
    List<int>? reminderOffsetsInMinutes,
    List<int>? notificationIds,
  }) => ReminderEvent(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    location: location ?? this.location,
    startDateTime: startDateTime ?? this.startDateTime,
    endDateTime: endDateTime ?? this.endDateTime,
    isAllDay: isAllDay ?? this.isAllDay,
    reminderOffsetsInMinutes:
        reminderOffsetsInMinutes ?? this.reminderOffsetsInMinutes,
    notificationIds: notificationIds ?? this.notificationIds,
  );

  factory ReminderEvent.fromJson(Map<String, dynamic> json) {
    final offsets =
        (json['reminder_offsets_minutes'] as List<dynamic>?)
            ?.map((e) => e as int)
            .toList() ??
        [];

    return ReminderEvent(
      id: json['id'] as String,
      title: json['title'] as String,
      description: json['description'] as String?,
      location: json['location'] as String?,
      startDateTime: DateTime.parse(json['start_datetime'] as String).toLocal(),
      endDateTime: json['end_datetime'] != null
          ? DateTime.parse(json['end_datetime'] as String).toLocal()
          : null,
      isAllDay: (json['is_all_day'] as bool?) ?? false,
      reminderOffsetsInMinutes: offsets,
      notificationIds: const [],
    );
  }

  Map<String, dynamic> toJson({required String employeeId}) => {
    'id': id,
    'employee_id': employeeId,
    'title': title,
    'description': description,
    'location': location,
    'start_datetime': startDateTime.toUtc().toIso8601String(),
    'end_datetime': endDateTime?.toUtc().toIso8601String(),
    'is_all_day': isAllDay,
    'reminder_offsets_minutes': reminderOffsetsInMinutes,
  };
}

// ─── WORK SCHEDULE SETTINGS ──────────────────────────────────────────────────

class WorkScheduleSettings {
  final Set<int> offDays;
  final List<int> defaultReminderOffsetsInMinutes;
  final bool autoMarkMissingAttendance;

  const WorkScheduleSettings({
    required this.offDays,
    required this.defaultReminderOffsetsInMinutes,
    required this.autoMarkMissingAttendance,
  });

  factory WorkScheduleSettings.defaults() => const WorkScheduleSettings(
    offDays: {6, 7},
    defaultReminderOffsetsInMinutes: [15, 5],
    autoMarkMissingAttendance: true,
  );

  factory WorkScheduleSettings.fromJson(Map<String, dynamic> json) {
    final offDays =
        (json['off_days'] as List<dynamic>?)?.map((e) => e as int).toSet() ??
        {6, 7};
    final offsets =
        (json['default_reminder_offsets_minutes'] as List<dynamic>?)
            ?.map((e) => e as int)
            .toList() ??
        [15, 5];

    return WorkScheduleSettings(
      offDays: offDays,
      defaultReminderOffsetsInMinutes: offsets,
      autoMarkMissingAttendance:
          (json['auto_mark_missing_attendance'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson({required String employeeId}) => {
    'employee_id': employeeId,
    'off_days': offDays.toList(),
    'default_reminder_offsets_minutes': defaultReminderOffsetsInMinutes,
    'auto_mark_missing_attendance': autoMarkMissingAttendance,
  };

  WorkScheduleSettings copyWith({
    Set<int>? offDays,
    List<int>? defaultReminderOffsetsInMinutes,
    bool? autoMarkMissingAttendance,
  }) => WorkScheduleSettings(
    offDays: offDays ?? this.offDays,
    defaultReminderOffsetsInMinutes:
        defaultReminderOffsetsInMinutes ?? this.defaultReminderOffsetsInMinutes,
    autoMarkMissingAttendance:
        autoMarkMissingAttendance ?? this.autoMarkMissingAttendance,
  );
}

// ─── EMPLOYEE PROFILE ────────────────────────────────────────────────────────

class EmployeeProfile {
  final String id;
  final String fullName;
  final String email;
  final String? avatarUrl;
  final String? department;
  final String? position;
  final String? phoneNumber;
  final bool notificationsEnabled;

  const EmployeeProfile({
    required this.id,
    required this.fullName,
    required this.email,
    this.avatarUrl,
    this.department,
    this.position,
    this.phoneNumber,
    this.notificationsEnabled = true,
  });

  String get initials {
    final parts = fullName.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return fullName.isNotEmpty ? fullName[0].toUpperCase() : '?';
  }

  factory EmployeeProfile.fromJson(Map<String, dynamic> json) =>
      EmployeeProfile(
        id: json['id'] as String,
        fullName: json['full_name'] as String,
        email: json['email'] as String,
        avatarUrl: json['avatar_url'] as String?,
        department: json['department'] as String?,
        position: json['position'] as String?,
        phoneNumber: json['phone_number'] as String?,
        notificationsEnabled: (json['notifications_enabled'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'full_name': fullName,
    'email': email,
    'avatar_url': avatarUrl,
    'department': department,
    'position': position,
    'phone_number': phoneNumber,
    'notifications_enabled': notificationsEnabled,
  };

  EmployeeProfile copyWith({
    String? fullName,
    String? avatarUrl,
    String? department,
    String? position,
    String? phoneNumber,
    bool? notificationsEnabled,
  }) => EmployeeProfile(
    id: id,
    fullName: fullName ?? this.fullName,
    email: email,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    department: department ?? this.department,
    position: position ?? this.position,
    phoneNumber: phoneNumber ?? this.phoneNumber,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
  );
}

// ─── PROJECT ────────────────────────────────────────────────────────────────

class Project {
  final String id;
  final String name;
  final Color color;

  const Project({required this.id, required this.name, required this.color});

  factory Project.fromJson(Map<String, dynamic> json) => Project(
    id: json['id'] as String,
    name: json['project_name'] as String,
    color: _colorFromHex(json['color'] as String),
  );

  Map<String, dynamic> toJson({required String employeeId}) => {
    'id': id,
    'employee_id': employeeId,
    'project_name': name,
    'color': _colorToHex(color),
  };

  static String _colorToHex(Color c) =>
      '#${c.r.round().toRadixString(16).padLeft(2, '0')}${c.g.round().toRadixString(16).padLeft(2, '0')}${c.b.round().toRadixString(16).padLeft(2, '0')}';

  static Color _colorFromHex(String hex) {
    final clean = hex.replaceFirst('#', '');
    return Color(int.parse('FF$clean', radix: 16));
  }
}
