import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../home/presentation/home_screen.dart';
import '../attendance/presentation/attendance_screen.dart';
import '../tracker/presentation/tracker_screen.dart';
import '../calendar/presentation/calendar_screen.dart';
import '../report/presentation/report_screen.dart';
import '../../shared/theme/app_colors.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  late AnimationController _fabController;
  late Animation<double> _fabScale;

  static const double _barHeight = 70;
  static const double _fabSize = 64;
  static const double _notchRadius = 40;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _fabScale = Tween<double>(
      begin: 1.0,
      end: 0.92,
    ).animate(CurvedAnimation(parent: _fabController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _fabController.dispose();
    super.dispose();
  }

  void _onTabSelected(int index) {
    if (_currentIndex == index) return;
    HapticFeedback.selectionClick();
    setState(() => _currentIndex = index);
  }

  void _onFabTap() {
    HapticFeedback.mediumImpact();
    _fabController.forward().then((_) => _fabController.reverse());
    _onTabSelected(2);
  }

  bool _isSelected(int index) => _currentIndex == index;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: AppColors.background,
      extendBody: true,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(onGoToTracker: () => _onTabSelected(1)),
          const TrackerScreen(),
          // AttendanceScreen menerima isActive=true HANYA saat tab Absensi
          // sedang dipilih, sehingga kamera tidak boot lebih awal saat user
          // masih di Home/Tracker, dan otomatis re-init saat user kembali.
          AttendanceScreen(
            isActive: _currentIndex == 2,
            onAttendanceSuccessDismissed: () => _onTabSelected(0),
          ),
          const CalendarScreen(),
          const ReportScreen(),
        ],
      ),
      bottomNavigationBar: SizedBox(
        height: _barHeight + _fabSize / 2 + bottomInset,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            // Curved bar
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: _buildCurvedBar(bottomInset),
              ),
            ),
            // Center FAB sits above the notch
            Positioned(
              bottom: _barHeight - _fabSize / 2 + bottomInset - 8,
              child: _buildFab(),
            ),
          ],
        ),
      ),
    );
  }

  // ─── CURVED BAR ──────────────────────────────────────────────────────────

  Widget _buildCurvedBar(double bottomInset) {
    return SizedBox(
      height: _barHeight + bottomInset,
      child: CustomPaint(
        painter: _CurvedBarPainter(
          notchRadius: _notchRadius,
          fillColor: AppColors.surface,
          borderColor: AppColors.border,
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _buildNavItem(
                        icon: Icons.home_rounded,
                        iconOutlined: Icons.home_outlined,
                        label: 'Home',
                        index: 0,
                      ),
                    ),
                    Expanded(
                      child: _buildNavItem(
                        icon: Icons.timer_rounded,
                        iconOutlined: Icons.timer_outlined,
                        label: 'Tracker',
                        index: 1,
                      ),
                    ),
                  ],
                ),
              ),
              // Space reserved for the notch / center button
              SizedBox(width: _notchRadius * 2 + 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _buildNavItem(
                        icon: Icons.calendar_month_rounded,
                        iconOutlined: Icons.calendar_month_outlined,
                        label: 'Kalender',
                        index: 3,
                      ),
                    ),
                    Expanded(
                      child: _buildNavItem(
                        icon: Icons.bar_chart_rounded,
                        iconOutlined: Icons.bar_chart_outlined,
                        label: 'Laporan',
                        index: 4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── CENTER FAB ──────────────────────────────────────────────────────────

  Widget _buildFab() {
    final selected = _isSelected(2);
    return ScaleTransition(
      scale: _fabScale,
      child: GestureDetector(
        onTap: _onFabTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _fabSize,
          height: _fabSize,
          padding: const EdgeInsets.all(4),
          decoration: const BoxDecoration(
            color: AppColors.background,
            shape: BoxShape.circle,
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? AppColors.primaryDark : AppColors.primary,
              border: Border.all(color: Colors.white, width: 3),
            ),
            child: Icon(
              selected
                  ? Icons.face_retouching_natural_rounded
                  : Icons.face_rounded,
              size: 31,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  // ─── NAV ITEM ────────────────────────────────────────────────────────────

  Widget _buildNavItem({
    required IconData icon,
    required IconData iconOutlined,
    required String label,
    required int index,
  }) {
    final selected = _isSelected(index);

    return GestureDetector(
      onTap: () => _onTabSelected(index),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: 48,
            height: 32,
            decoration: BoxDecoration(
              color: selected ? AppColors.primaryLight : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: Icon(
                  selected ? icon : iconOutlined,
                  key: ValueKey('${index}_$selected'),
                  size: selected ? 23 : 22,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            child: Text(label),
          ),
        ],
      ),
    );
  }
}

// ─── CUSTOM CURVED BAR PAINTER ─────────────────────────────────────────────

class _CurvedBarPainter extends CustomPainter {
  final double notchRadius;
  final Color fillColor;
  final Color borderColor;

  _CurvedBarPainter({
    required this.notchRadius,
    required this.fillColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;

    // Elegant wide curve — wider than the notch to look smooth
    final notchWidth = notchRadius * 2 + 42;
    final leftNotch = centerX - notchWidth / 2;
    final rightNotch = centerX + notchWidth / 2;
    final dipDepth = notchRadius * 1.16;

    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(leftNotch, 0);

    // Entry curve down into the notch
    path.cubicTo(
      leftNotch + notchWidth * 0.20,
      0,
      centerX - notchWidth * 0.36,
      dipDepth,
      centerX,
      dipDepth,
    );
    // Exit curve up from the notch
    path.cubicTo(
      centerX + notchWidth * 0.36,
      dipDepth,
      rightNotch - notchWidth * 0.20,
      0,
      rightNotch,
      0,
    );

    path.lineTo(size.width, 0);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    // Fill
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // Top border stroke (only the curved top edge)
    final borderPath = Path();
    borderPath.moveTo(0, 0);
    borderPath.lineTo(leftNotch, 0);
    borderPath.cubicTo(
      leftNotch + notchWidth * 0.20,
      0,
      centerX - notchWidth * 0.36,
      dipDepth,
      centerX,
      dipDepth,
    );
    borderPath.cubicTo(
      centerX + notchWidth * 0.36,
      dipDepth,
      rightNotch - notchWidth * 0.20,
      0,
      rightNotch,
      0,
    );
    borderPath.lineTo(size.width, 0);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(borderPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _CurvedBarPainter oldDelegate) =>
      oldDelegate.notchRadius != notchRadius ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.borderColor != borderColor;
}
