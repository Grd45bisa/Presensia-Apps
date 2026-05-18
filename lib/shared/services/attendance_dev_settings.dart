import 'package:flutter/foundation.dart';

class AttendanceDevSettings extends ChangeNotifier {
  AttendanceDevSettings._();

  static final AttendanceDevSettings instance = AttendanceDevSettings._();

  bool _requireBlinkForAttendance = false;

  bool get requireBlinkForAttendance => _requireBlinkForAttendance;

  void setRequireBlinkForAttendance(bool value) {
    if (_requireBlinkForAttendance == value) return;
    _requireBlinkForAttendance = value;
    notifyListeners();
  }
}
