import 'dart:async';
import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class AttendanceGeofenceService {
  AttendanceGeofenceService._();
  static final AttendanceGeofenceService instance =
      AttendanceGeofenceService._();

  static const Duration _positionCacheTtl = Duration(seconds: 30);

  static const String _baseUrl = String.fromEnvironment(
    'PRESENSIA_BACKEND_URL',
    defaultValue: 'https://apipre.kitapunya.web.id',
  );

  Position? _cachedPosition;
  DateTime? _cachedPositionAt;

  Future<void> prepareLocationAccess() async {
    await _currentPosition(allowCached: true);
  }

  Future<GeofenceValidationResult> validate(String employeeId) async {
    final position = await _currentPosition(allowCached: false);
    final uri = Uri.parse('$_baseUrl/api/mobile/attendance/validate-geofence');

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'employee_id': employeeId,
            'latitude': position.latitude,
            'longitude': position.longitude,
            'accuracy_meters': position.accuracy,
            'is_mock_location': position.isMocked,
          }),
        )
        .timeout(const Duration(seconds: 20));

    final payload =
        jsonDecode(response.body.isEmpty ? '{}' : response.body)
            as Map<String, dynamic>;

    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        payload['success'] == false) {
      throw StateError(
        payload['message'] as String? ?? 'Validasi lokasi kantor gagal.',
      );
    }

    return GeofenceValidationResult.fromJson(
      payload['validation'] as Map<String, dynamic>? ?? {},
      position: position,
    );
  }

  Future<Position> _currentPosition({required bool allowCached}) async {
    final cached = _cachedPosition;
    final cachedAt = _cachedPositionAt;
    if (allowCached && cached != null && cachedAt != null) {
      final age = DateTime.now().difference(cachedAt);
      if (age <= _positionCacheTtl) return cached;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const GeofencePermissionException(
        'GPS/lokasi perangkat wajib aktif untuk presensi. Aktifkan lokasi lalu coba lagi.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw const GeofencePermissionException(
        'Izin lokasi wajib diberikan agar aplikasi bisa mengambil data GPS untuk presensi.',
      );
    }

    if (permission == LocationPermission.deniedForever) {
      throw const GeofencePermissionException(
        'Izin lokasi ditolak permanen. Aktifkan izin lokasi Presensia dari pengaturan aplikasi sebelum presensi.',
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 15),
        ),
      );
      _cachedPosition = position;
      _cachedPositionAt = DateTime.now();
      return position;
    } on LocationServiceDisabledException {
      throw const GeofencePermissionException(
        'GPS/lokasi perangkat terdeteksi mati. Presensi tidak bisa dilanjutkan.',
      );
    } on PermissionDeniedException {
      throw const GeofencePermissionException(
        'Izin lokasi belum diberikan. Presensi tidak bisa dilanjutkan.',
      );
    } on TimeoutException {
      throw const GeofencePermissionException(
        'Data GPS belum terbaca. Pastikan lokasi aktif, lalu coba presensi lagi.',
      );
    }
  }
}

class GeofenceValidationResult {
  const GeofenceValidationResult({
    required this.allowed,
    required this.geofenceStatus,
    required this.attendanceMode,
    required this.canAttendOutsideOffice,
    required this.message,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.isMockLocation,
    this.distanceMeters,
    this.radiusMeters,
    this.officeLocation,
  });

  final bool allowed;
  final String geofenceStatus;
  final String attendanceMode;
  final bool canAttendOutsideOffice;
  final String message;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final bool isMockLocation;
  final int? distanceMeters;
  final int? radiusMeters;
  final OfficeGeofenceLocation? officeLocation;

  bool get requiresOfficeGeofence =>
      attendanceMode == 'office' && !canAttendOutsideOffice;

  factory GeofenceValidationResult.fromJson(
    Map<String, dynamic> json, {
    required Position position,
  }) =>
      GeofenceValidationResult(
        allowed: json['allowed'] != false,
        geofenceStatus: json['geofence_status'] as String? ?? 'unknown',
        attendanceMode: json['attendance_mode'] as String? ?? 'office',
        canAttendOutsideOffice: json['can_attend_outside_office'] == true,
        message: json['message'] as String? ?? '',
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        isMockLocation: position.isMocked,
        distanceMeters: (json['distance_meters'] as num?)?.round(),
        radiusMeters: (json['radius_meters'] as num?)?.round(),
        officeLocation: json['office_location'] is Map
            ? OfficeGeofenceLocation.fromJson(
                Map<String, dynamic>.from(json['office_location'] as Map),
              )
            : null,
      );
}

class OfficeGeofenceLocation {
  const OfficeGeofenceLocation({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    this.address,
  });

  final String id;
  final String name;
  final String? address;
  final double latitude;
  final double longitude;
  final int radiusMeters;

  factory OfficeGeofenceLocation.fromJson(Map<String, dynamic> json) =>
      OfficeGeofenceLocation(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Kantor',
        address: json['address'] as String?,
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
        radiusMeters: (json['radius_meters'] as num?)?.round() ?? 100,
      );
}

class GeofencePermissionException implements Exception {
  const GeofencePermissionException(this.message);

  final String message;

  @override
  String toString() => message;
}
