import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// Data model yang di-pass dari ReportScreen
class ReportPdfData {
  final String employeeName;
  final String employeeEmail;
  final String? department;
  final String? position;
  final DateTime startDate;
  final DateTime endDate;

  // Statistik utama
  final int presentDays;
  final int workdayTarget;
  final int missingDays;
  final int offDays;
  final int totalEntries;
  final Duration totalWorkDuration;
  final int onTimeCount;
  final int daysWithCheckIn;

  // Bucket mingguan untuk bar chart
  final List<ReportBucket> buckets;

  const ReportPdfData({
    required this.employeeName,
    required this.employeeEmail,
    this.department,
    this.position,
    required this.startDate,
    required this.endDate,
    required this.presentDays,
    required this.workdayTarget,
    required this.missingDays,
    required this.offDays,
    required this.totalEntries,
    required this.totalWorkDuration,
    required this.onTimeCount,
    required this.daysWithCheckIn,
    required this.buckets,
  });

  double get punctualityPct =>
      daysWithCheckIn == 0 ? 0 : onTimeCount / daysWithCheckIn * 100;

  String get totalWorkLabel {
    final h = totalWorkDuration.inHours;
    final m = totalWorkDuration.inMinutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}j';
    return '${h}j ${m.toString().padLeft(2, '0')}m';
  }

  String get avgWorkLabel {
    if (daysWithCheckIn == 0) return '0j';
    final avgMin = totalWorkDuration.inMinutes ~/ daysWithCheckIn;
    final h = avgMin ~/ 60;
    final m = avgMin % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}j';
    return '${h}j ${m.toString().padLeft(2, '0')}m';
  }
}

class ReportBucket {
  final DateTime start;
  final DateTime end;
  final double hours;
  const ReportBucket({
    required this.start,
    required this.end,
    required this.hours,
  });
}

class ReportPdfService {
  static const _primaryColor = PdfColor.fromInt(0xFF1565C0);
  static const _successColor = PdfColor.fromInt(0xFF1B5E20);
  static const _errorColor = PdfColor.fromInt(0xFFB71C1C);
  static const _warningColor = PdfColor.fromInt(0xFFFF8F00);
  static const _bgColor = PdfColor.fromInt(0xFFF5F7FA);
  static const _borderColor = PdfColor.fromInt(0xFFE5E7EB);
  static const _textPrimary = PdfColor.fromInt(0xFF1A1A2E);
  static const _textSecondary = PdfColor.fromInt(0xFF6B7280);

  /// Generate PDF document dari data laporan.
  static pw.Document generate(ReportPdfData data) {
    final doc = pw.Document(
      title: 'Laporan Presensia - ${data.employeeName}',
      author: 'Presensia',
    );

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _buildHeader(data),
              pw.SizedBox(height: 10),
              _buildEmployeeCard(data),
              pw.SizedBox(height: 12),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    flex: 5,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        _buildStatsGrid(data),
                        pw.SizedBox(height: 10),
                        _buildDistributionSection(data),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 14),
                  pw.Expanded(
                    flex: 5,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        _buildBarChart(data),
                        pw.SizedBox(height: 10),
                        _buildInsightSection(data),
                      ],
                    ),
                  ),
                ],
              ),
              pw.Spacer(),
              _buildFooter(ctx),
            ],
          );
        },
      ),
    );

    return doc;
  }

  // ── Header ────────────────────────────────────────────────────────────────

  static pw.Widget _buildHeader(ReportPdfData data) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Presensia',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: _primaryColor,
                  ),
                ),
                pw.SizedBox(height: 1),
                pw.Text(
                  'Laporan Performa Karyawan',
                  style: pw.TextStyle(fontSize: 10, color: _textSecondary),
                ),
              ],
            ),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 5,
              ),
              decoration: pw.BoxDecoration(
                color: _primaryColor,
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Text(
                '${_dateShort(data.startDate)} - ${_dateShort(data.endDate)}',
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Divider(color: _borderColor, thickness: 0.75),
      ],
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────────

  static pw.Widget _buildFooter(pw.Context ctx) {
    return pw.Column(
      children: [
        pw.Divider(color: _borderColor, thickness: 0.75),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Digenerate oleh Presensia - ${_dateShort(DateTime.now())}',
              style: pw.TextStyle(fontSize: 7.5, color: _textSecondary),
            ),
            pw.Text(
              'Halaman ${ctx.pageNumber} dari ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 7.5, color: _textSecondary),
            ),
          ],
        ),
      ],
    );
  }

  // ── Employee card ─────────────────────────────────────────────────────────

  static pw.Widget _buildEmployeeCard(ReportPdfData data) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: pw.BoxDecoration(
        color: _bgColor,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: _borderColor),
      ),
      child: pw.Row(
        children: [
          // Avatar circle
          pw.Container(
            width: 36,
            height: 36,
            decoration: pw.BoxDecoration(
              color: _primaryColor,
              shape: pw.BoxShape.circle,
            ),
            alignment: pw.Alignment.center,
            child: pw.Text(
              data.employeeName.isNotEmpty
                  ? data.employeeName[0].toUpperCase()
                  : '?',
              style: pw.TextStyle(
                color: PdfColors.white,
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                data.employeeName,
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                  color: _textPrimary,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                data.employeeEmail,
                style: pw.TextStyle(fontSize: 9, color: _textSecondary),
              ),
              if (data.department != null || data.position != null)
                pw.SizedBox(height: 1),
              if (data.department != null || data.position != null)
                pw.Text(
                  [
                    data.position,
                    data.department,
                  ].where((e) => e != null).join(' | '),
                  style: pw.TextStyle(fontSize: 9, color: _textSecondary),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Stats grid 3x2 ────────────────────────────────────────────────────────

  static pw.Widget _buildStatsGrid(ReportPdfData data) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Statistik Periode'),
        pw.SizedBox(height: 6),
        pw.Row(
          children: [
            pw.Expanded(
              child: _statCard(
                label: 'Hari Hadir',
                value: '${data.presentDays}',
                sub: 'dari ${data.workdayTarget} hari kerja',
                color: _successColor,
              ),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: _statCard(
                label: 'Tidak Hadir',
                value: '${data.missingDays}',
                sub: 'hari tanpa absensi',
                color: _errorColor,
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          children: [
            pw.Expanded(
              child: _statCard(
                label: 'Total Jam Kerja',
                value: data.totalWorkLabel,
                sub: 'dari tracker',
                color: _primaryColor,
              ),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: _statCard(
                label: 'Rata-rata Harian',
                value: data.avgWorkLabel,
                sub: 'per hari hadir',
                color: _primaryColor,
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          children: [
            pw.Expanded(
              child: _statCard(
                label: 'Ketepatan Waktu',
                value: '${data.punctualityPct.toStringAsFixed(0)}%',
                sub: '${data.onTimeCount} dari ${data.daysWithCheckIn} hari',
                color: data.punctualityPct >= 80 ? _successColor : _warningColor,
              ),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: _statCard(
                label: 'Total Entry',
                value: '${data.totalEntries}',
                sub: 'catatan pekerjaan',
                color: _textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _statCard({
    required String label,
    required String value,
    required String sub,
    required PdfColor color,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: _borderColor),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(fontSize: 8, color: _textSecondary),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 15,
              fontWeight: pw.FontWeight.bold,
              color: color,
            ),
          ),
          pw.SizedBox(height: 1),
          pw.Text(sub, style: pw.TextStyle(fontSize: 7, color: _textSecondary)),
        ],
      ),
    );
  }

  // ── Distribution section ──────────────────────────────────────────────────

  static pw.Widget _buildDistributionSection(ReportPdfData data) {
    final total = (data.presentDays + data.missingDays + data.offDays).clamp(
      1,
      9999,
    );
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Distribusi Kehadiran'),
        pw.SizedBox(height: 6),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            borderRadius: pw.BorderRadius.circular(8),
            border: pw.Border.all(color: _borderColor),
          ),
          child: pw.Column(
            children: [
              _distRow('Hadir', data.presentDays, total, _successColor),
              pw.SizedBox(height: 6),
              _distRow('Tidak Hadir', data.missingDays, total, _errorColor),
              pw.SizedBox(height: 6),
              _distRow('Hari Libur', data.offDays, total, _warningColor),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _distRow(
    String label,
    int count,
    int total,
    PdfColor color,
  ) {
    final ratio = (count / total).clamp(0.0, 1.0);
    const barWidth = 100.0;
    final filledWidth = barWidth * ratio;
    final emptyWidth = barWidth - filledWidth;

    return pw.Row(
      children: [
        pw.SizedBox(
          width: 60,
          child: pw.Text(
            label,
            style: pw.TextStyle(fontSize: 9, color: _textPrimary),
          ),
        ),
        pw.SizedBox(width: 6),
        // filled portion
        if (filledWidth > 0)
          pw.Container(
            width: filledWidth,
            height: 7,
            decoration: pw.BoxDecoration(
              color: color,
              borderRadius: pw.BorderRadius.circular(3.5),
            ),
          ),
        // empty remainder
        if (emptyWidth > 0)
          pw.Container(
            width: emptyWidth,
            height: 7,
            decoration: pw.BoxDecoration(
              color: _bgColor,
              borderRadius: pw.BorderRadius.circular(3.5),
            ),
          ),
        pw.SizedBox(width: 6),
        pw.Text(
          '$count hari (${(ratio * 100).toStringAsFixed(0)}%)',
          style: pw.TextStyle(fontSize: 8, color: _textSecondary),
        ),
      ],
    );
  }

  // ── Bar chart ─────────────────────────────────────────────────────────────

  static pw.Widget _buildBarChart(ReportPdfData data) {
    if (data.buckets.isEmpty) return pw.SizedBox();

    final maxHours = data.buckets.fold<double>(
      0,
      (prev, b) => b.hours > prev ? b.hours : prev,
    );
    final chartMax = maxHours == 0 ? 8.0 : (maxHours * 1.2).ceilToDouble();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Jam Kerja per Periode'),
        pw.SizedBox(height: 6),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            borderRadius: pw.BorderRadius.circular(8),
            border: pw.Border.all(color: _borderColor),
          ),
          child: pw.Column(
            children: [
              pw.SizedBox(
                height: 80,
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                  children: data.buckets.map((bucket) {
                    final heightRatio = chartMax == 0
                        ? 0.0
                        : (bucket.hours / chartMax).clamp(0.0, 1.0);
                    final isPeak = bucket.hours == maxHours && maxHours > 0;
                    return pw.Expanded(
                      child: pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(horizontal: 3),
                        child: pw.Column(
                          mainAxisAlignment: pw.MainAxisAlignment.end,
                          children: [
                            if (bucket.hours > 0)
                              pw.Text(
                                '${bucket.hours.toStringAsFixed(1)}j',
                                style: pw.TextStyle(
                                  fontSize: 7,
                                  color: isPeak
                                      ? _primaryColor
                                      : _textSecondary,
                                  fontWeight: isPeak
                                      ? pw.FontWeight.bold
                                      : null,
                                ),
                              ),
                            pw.SizedBox(height: 2),
                            pw.Container(
                              height: 60 * heightRatio,
                              decoration: pw.BoxDecoration(
                                color: isPeak
                                    ? _primaryColor
                                    : const PdfColor.fromInt(0xFF90CAF9),
                                borderRadius: const pw.BorderRadius.only(
                                  topLeft: pw.Radius.circular(3),
                                  topRight: pw.Radius.circular(3),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                children: data.buckets.map((bucket) {
                  return pw.Expanded(
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 2),
                      child: pw.Text(
                        _bucketLabel(bucket.start, bucket.end),
                        style: pw.TextStyle(fontSize: 6.5, color: _textSecondary),
                        textAlign: pw.TextAlign.center,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Insight section ───────────────────────────────────────────────────────

  static pw.Widget _buildInsightSection(ReportPdfData data) {
    final insights = <String>[];

    final attendancePct = data.workdayTarget == 0
        ? 0.0
        : data.presentDays / data.workdayTarget * 100;

    if (attendancePct >= 90) {
      insights.add(
        'Kehadiran sangat baik: ${attendancePct.toStringAsFixed(0)}% dari target hari kerja.',
      );
    } else if (attendancePct >= 70) {
      insights.add(
        'Kehadiran cukup baik: ${attendancePct.toStringAsFixed(0)}% dari target. Masih ada ruang untuk peningkatan.',
      );
    } else if (data.workdayTarget > 0) {
      insights.add(
        'Kehadiran perlu ditingkatkan: ${attendancePct.toStringAsFixed(0)}% dari target hari kerja.',
      );
    }

    if (data.punctualityPct >= 90) {
      insights.add(
        'Ketepatan waktu sangat baik: ${data.punctualityPct.toStringAsFixed(0)}% check-in tepat waktu.',
      );
    } else if (data.punctualityPct > 0) {
      insights.add(
        'Ketepatan waktu: ${data.punctualityPct.toStringAsFixed(0)}% (${data.onTimeCount} dari ${data.daysWithCheckIn} hari check-in tepat waktu).',
      );
    }

    if (data.totalEntries > 0) {
      insights.add(
        'Total ${data.totalEntries} entri pekerjaan tercatat dengan total ${data.totalWorkLabel} jam kerja.',
      );
    }

    if (insights.isEmpty) {
      insights.add(
        'Belum ada data yang cukup untuk menghasilkan insight pada periode ini.',
      );
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Insight'),
        pw.SizedBox(height: 6),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            borderRadius: pw.BorderRadius.circular(8),
            border: pw.Border.all(color: _borderColor),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: insights
                .map(
                  (insight) => pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 4),
                    child: pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(
                          width: 4,
                          height: 4,
                          margin: const pw.EdgeInsets.only(top: 3.5, right: 6),
                          decoration: pw.BoxDecoration(
                            color: _primaryColor,
                            shape: pw.BoxShape.circle,
                          ),
                        ),
                        pw.Expanded(
                          child: pw.Text(
                            insight,
                            style: pw.TextStyle(
                              fontSize: 8.5,
                              color: _textPrimary,
                              lineSpacing: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static pw.Widget _sectionTitle(String title) {
    return pw.Text(
      title,
      style: pw.TextStyle(
        fontSize: 11,
        fontWeight: pw.FontWeight.bold,
        color: _textPrimary,
      ),
    );
  }

  static String _dateShort(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agt',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  static String _bucketLabel(DateTime start, DateTime end) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agt',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    if (start.month == end.month) {
      return '${start.day}-${end.day}\n${months[start.month - 1]}';
    }
    return '${start.day}${months[start.month - 1]}-${end.day}${months[end.month - 1]}';
  }
}
