import 'package:flutter/material.dart';
import '../../../shared/models/app_notification.dart';
import '../../../shared/providers/notification_provider.dart';
import '../../../shared/theme/app_colors.dart';

void showNotificationPanel(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _NotificationPanel(),
  );
}

class _NotificationPanel extends StatefulWidget {
  const _NotificationPanel();

  @override
  State<_NotificationPanel> createState() => _NotificationPanelState();
}

class _NotificationPanelState extends State<_NotificationPanel> {
  final _provider = NotificationProvider.instance;

  @override
  void initState() {
    super.initState();
    _provider.ensureReadStateLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final notifications = _provider.compute();
    final unread = notifications.where((n) => !n.isRead).length;
    final media = MediaQuery.of(context);
    final bottomInset = media.padding.bottom > 0
        ? media.padding.bottom
        : media.viewPadding.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollCtrl) {
        return Column(
          children: [
            // ── Handle & Header
            _buildHeader(unread),
            const Divider(height: 1, color: AppColors.border),
            // ── List
            Expanded(
              child: notifications.isEmpty
                  ? _buildEmpty()
                  : ListView.separated(
                      controller: scrollCtrl,
                      padding: EdgeInsets.fromLTRB(0, 8, 0, 12 + bottomInset),
                      itemCount: notifications.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 1,
                        indent: 64,
                        endIndent: 16,
                        color: AppColors.border,
                      ),
                      itemBuilder: (_, i) => _NotificationTile(
                        item: notifications[i],
                        onTap: () {
                          setState(
                            () => _provider.markRead(notifications[i].id),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(int unread) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Text(
                'Notifikasi',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: AppColors.textPrimary,
                ),
              ),
              if (unread > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$unread baru',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (unread > 0)
                TextButton(
                  onPressed: () => setState(() => _provider.markAllRead()),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Tandai semua dibaca',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            child: const Icon(
              Icons.notifications_none_rounded,
              size: 36,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Belum ada notifikasi',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Semua aktivitas kerja kamu sudah beres.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification item;
  final VoidCallback onTap;

  const _NotificationTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isUnread = !item.isRead;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: isUnread
            ? AppColors.primary.withValues(alpha: 0.03)
            : AppColors.background.withValues(alpha: 0.45),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isUnread
                    ? item.iconBg
                    : AppColors.border.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                item.icon,
                color: isUnread
                    ? item.iconColor
                    : AppColors.textSecondary.withValues(alpha: 0.72),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isUnread
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isUnread
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        item.timeLabel,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      item.subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary.withValues(
                          alpha: isUnread ? 1 : 0.72,
                        ),
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 5),
                  _CategoryChip(category: item.category),
                ],
              ),
            ),
            // Unread dot
            if (isUnread)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(top: 4, left: 6),
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final NotificationCategory category;

  const _CategoryChip({required this.category});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (category) {
      NotificationCategory.calendar => (
        'Pengingat Kalender',
        AppColors.primary,
      ),
      NotificationCategory.attendance => ('Status Absensi', AppColors.missing),
      NotificationCategory.tracker => (
        'Status Tracker',
        AppColors.textSecondary,
      ),
      NotificationCategory.schedule => ('Info Jadwal', AppColors.error),
      NotificationCategory.system => ('Info Sistem', AppColors.textSecondary),
    };

    return Text(
      label,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: color.withValues(alpha: 0.75),
        letterSpacing: 0.2,
      ),
    );
  }
}
