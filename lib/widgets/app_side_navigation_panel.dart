import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/user_profile_model.dart';
import '../screens/welcome_auth_screen.dart';
import '../services/auto_sync_service.dart';
import '../services/document_storage_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import 'user_avatar_widget.dart';

enum SidebarNavItem {
  dashboard,
  documents,
  notes,
  settings,
  switchAccount,
}

class AppSideNavigationPanel extends StatefulWidget {
  final SidebarNavItem selectedItem;
  final ValueChanged<SidebarNavItem>? onItemSelected;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final VoidCallback? onCloseDrawer;
  final bool isDrawerMode;

  const AppSideNavigationPanel({
    super.key,
    this.selectedItem = SidebarNavItem.dashboard,
    this.onItemSelected,
    this.initiallyExpanded = true,
    this.onExpansionChanged,
    this.onCloseDrawer,
    this.isDrawerMode = false,
  });

  @override
  State<AppSideNavigationPanel> createState() => _AppSideNavigationPanelState();
}

class _AppSideNavigationPanelState extends State<AppSideNavigationPanel> {
  late bool _isExpanded;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  void _toggleExpansion() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
    widget.onExpansionChanged?.call(_isExpanded);
  }

  Future<void> _handleQuickSync() async {
    setState(() => _isSyncing = true);
    await AutoSyncService.instance.syncAllToCloud();
    if (mounted) {
      setState(() => _isSyncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(CupertinoIcons.checkmark_seal_fill,
                  color: Color(0xFF10B981), size: 16),
              SizedBox(width: 8),
              Text('Cloud sync complete!',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          backgroundColor: AppTheme.primaryPurpleDark,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _onItemTapped(SidebarNavItem item) {
    widget.onItemSelected?.call(item);
    if (widget.isDrawerMode && widget.onCloseDrawer != null) {
      widget.onCloseDrawer!();
    }
  }

  void _openSettings() {
    widget.onItemSelected?.call(SidebarNavItem.settings);
  }

  /// Opens the unified, clean Switch Account & Session Management Modal
  void _openSwitchAccountModal() {
    widget.onItemSelected?.call(SidebarNavItem.switchAccount);
  }

  @override
  Widget build(BuildContext context) {
    final panelWidth = _isExpanded ? 270.0 : 78.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      width: widget.isDrawerMode ? 290.0 : panelWidth,
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        border: const Border(
          right: BorderSide(
            color: AppTheme.dividerColor,
            width: 1.0,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryPurple.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(3, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── 1. TOP HEADER (Promoted Profile + Close X / Toggle) ──
            _buildTopProfileHeader(),

            const Divider(height: 1, color: AppTheme.dividerColor),

            // ── 2. SCROLLABLE NAVIGATION CONTENT ──
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 10),
                children: [
                  // Section 1: Workspace
                  if (_isExpanded) _buildSectionHeader('WORKSPACE'),
                  _buildNavItem(
                    item: SidebarNavItem.dashboard,
                    icon: CupertinoIcons.square_grid_2x2_fill,
                    label: 'Dashboard',
                    badge: null,
                  ),
                  _buildNavItem(
                    item: SidebarNavItem.documents,
                    icon: CupertinoIcons.doc_text_fill,
                    label: 'Documents & Images',
                    badge: null,
                  ),
                  _buildNavItem(
                    item: SidebarNavItem.notes,
                    icon: CupertinoIcons.pencil_outline,
                    label: 'Handwritten Notes',
                    badge: null,
                  ),

                  const SizedBox(height: 14),

                  // Section 2: Account & System (Clean Unified Buttons)
                  if (_isExpanded) _buildSectionHeader('ACCOUNT & SYSTEM'),
                  _buildNavItem(
                    item: SidebarNavItem.switchAccount,
                    icon: CupertinoIcons.person_2_fill,
                    label: 'Switch Account',
                    badge: 'Profiles',
                    badgeColor: const Color(0xFF10B981),
                    onOverrideTap: _openSwitchAccountModal,
                  ),
                  _buildNavItem(
                    item: SidebarNavItem.settings,
                    icon: CupertinoIcons.gear_alt_fill,
                    label: 'Profile Settings',
                    badge: 'Edit',
                    badgeColor: AppTheme.primaryPurple,
                    onOverrideTap: _openSettings,
                  ),
                ],
              ),
            ),

            // ── 3. FOOTER AREA (Single Sync Button & Simple Version) ──
            const Divider(height: 1, color: AppTheme.dividerColor),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 1. TOP HEADER (User Profile + Close X Button)
  // ===========================================================================

  Widget _buildTopProfileHeader() {
    return ValueListenableBuilder<UserProfile?>(
      valueListenable: UserService.instance.currentUserNotifier,
      builder: (context, user, _) {
        final displayName = user?.name ?? 'Ayen';
        final isCloud = user?.isCloudLinked ?? false;
        final emailText = isCloud
            ? (user?.email ?? 'Cloud Synced')
            : 'Offline Local Storage';

        if (!_isExpanded && !widget.isDrawerMode) {
          // Collapsed Top View
          return Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Tooltip(
                message: '$displayName\n$emailText\n(Tap for Profile Settings)',
                child: GestureDetector(
                  onTap: _openSettings,
                  behavior: HitTestBehavior.opaque,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      UserAvatarWidget(
                        user: user,
                        size: 44,
                      ),
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: isCloud
                              ? const Color(0xFF10B981)
                              : const Color(0xFF94A3B8),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        // Expanded Top Header (Profile info on left, Close X button on right)
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Row(
            children: [
              // Profile Card Info (Tapping opens Profile Settings)
              Expanded(
                child: GestureDetector(
                  onTap: _openSettings,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      // Large Circular Avatar
                      UserAvatarWidget(
                        user: user,
                        size: 44,
                      ),
                      const SizedBox(width: 12),

                      // Name and Email
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              displayName,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              emailText,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Close (X) Icon Button (aligned in top-right)
              if (widget.isDrawerMode)
                IconButton(
                  icon: const Icon(CupertinoIcons.xmark,
                      size: 18, color: AppTheme.textSecondary),
                  tooltip: 'Close drawer',
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                  splashRadius: 20,
                  onPressed: widget.onCloseDrawer,
                )
              else
                IconButton(
                  icon: const Icon(CupertinoIcons.sidebar_left,
                      size: 20, color: AppTheme.textSecondary),
                  tooltip: 'Collapse sidebar',
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                  splashRadius: 20,
                  onPressed: _toggleExpansion,
                ),
            ],
          ),
        );
      },
    );
  }

  // ===========================================================================
  // SECTION HEADER
  // ===========================================================================

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 14, 6),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: AppTheme.textMuted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  // ===========================================================================
  // NAVIGATION ITEM
  // ===========================================================================

  Widget _buildNavItem({
    required SidebarNavItem item,
    required IconData icon,
    required String label,
    String? badge,
    Color? badgeColor,
    VoidCallback? onOverrideTap,
  }) {
    final isSelected = widget.selectedItem == item;

    if (!_isExpanded && !widget.isDrawerMode) {
      // Collapsed Icon-Only View
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Tooltip(
          message: label,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onOverrideTap ?? () => _onItemTapped(item),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: isSelected ? AppTheme.primaryGradient : null,
                  color: isSelected ? null : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: AppTheme.primaryPurple
                                .withValues(alpha: 0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Icon(
                    icon,
                    size: 20,
                    color: isSelected ? Colors.white : AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Expanded Full Menu Item
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onOverrideTap ?? () => _onItemTapped(item),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: isSelected ? AppTheme.primaryGradient : null,
              color: isSelected ? null : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: isSelected ? Colors.white : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),

                // Label
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          isSelected ? FontWeight.w800 : FontWeight.w600,
                      color: isSelected ? Colors.white : AppTheme.textPrimary,
                      letterSpacing: -0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // Badge Tag
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: (badgeColor ?? AppTheme.primaryPurple)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: badgeColor ?? AppTheme.primaryPurple,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // 4. FOOTER (Single Sync Button & Simple Version Text)
  // ===========================================================================

  Widget _buildFooter() {
    if (!_isExpanded && !widget.isDrawerMode) {
      // Collapsed Footer
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Tooltip(
          message: 'Sync Cloud Backup',
          child: IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.primaryPurple,
                    ),
                  )
                : const Icon(CupertinoIcons.arrow_2_circlepath,
                    size: 18, color: AppTheme.textSecondary),
            onPressed: _isSyncing ? null : _handleQuickSync,
          ),
        ),
      );
    }

    // Expanded Footer (Single sync button and clean version text)
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        children: [
          // Single "Sync Cloud Backup" Button
          SizedBox(
            width: double.infinity,
            height: 38,
            child: OutlinedButton.icon(
              onPressed: _isSyncing ? null : _handleQuickSync,
              icon: _isSyncing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primaryPurple,
                      ),
                    )
                  : const Icon(CupertinoIcons.arrow_2_circlepath,
                      size: 14, color: AppTheme.primaryPurple),
              label: Text(
                _isSyncing ? 'Syncing...' : 'Sync Cloud Backup',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryPurple,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.dividerColor),
                backgroundColor: AppTheme.surfaceWhite,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Simple clean version text
          const Text(
            'v1.2.0',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// UNIFIED SWITCH ACCOUNT & SESSION MANAGEMENT BOTTOM SHEET
// =============================================================================

class SwitchAccountBottomSheet extends StatelessWidget {
  const SwitchAccountBottomSheet({super.key});

  void _navigateToAddProfile(BuildContext context) {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (context) => const WelcomeAuthScreen(canCancel: true),
      ),
    );
  }

  Future<void> _handleSwitchProfile(
      BuildContext context, String profileId) async {
    final activeId = UserService.instance.currentUser?.id;
    if (activeId == profileId) {
      Navigator.of(context).pop();
      return;
    }

    final list = UserService.instance.profilesListNotifier.value;
    final target = list.firstWhere(
      (p) => p.id == profileId,
      orElse: () => list.first,
    );

    // 1. Show sleek loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: AppTheme.surfaceWhite,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryPurple.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.8,
                    color: AppTheme.primaryPurple,
                  ),
                ),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Switching to ${target.name}...',
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Loading user notebook workspace',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // 2. Perform switch & sync
    await UserService.instance.switchProfile(profileId);

    await Future.delayed(const Duration(milliseconds: 350));

    // 3. Pop loading dialog
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }

    // 4. Pop SwitchAccountBottomSheet with success flag
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }

    // 5. Verification toast
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              UserAvatarWidget(
                user: target,
                size: 28,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Switched to ${target.name}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      target.isCloudLinked
                          ? (target.email ?? 'Cloud Synced')
                          : 'Offline Local Account',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          backgroundColor: AppTheme.primaryPurpleDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _handleDeleteProfile(
      BuildContext context, UserProfile targetProfile) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Remove "${targetProfile.name}"?'),
        content: const Text(
          'Are you sure you want to remove this profile from this device? Cloud-synced data will remain safe in your cloud account.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Remove Profile'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await UserService.instance.deleteProfile(targetProfile.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Profile "${targetProfile.name}" removed from device.'),
            backgroundColor: AppTheme.primaryPurpleDark,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleResetLocalCache(BuildContext context) async {
    final user = UserService.instance.currentUser;
    if (user == null) return;

    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Reset Local Cache?'),
        content: const Text(
          'This will clear local device files for this profile and re-download fresh data from the cloud.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Reset Cache'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DocumentStorageService.deleteAllUserData(user.id);
      await AutoSyncService.instance.syncAllToCloud();
      UserService.instance.currentUserNotifier.value = user;
      if (context.mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Local cache reset for ${user.name}. Fresh cloud sync complete.'),
            backgroundColor: const Color(0xFF2E7D32),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  Future<void> _handleLogout(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Log Out of Account?'),
        content: const Text(
          'Your profile and notes remain safely saved on this device. You can easily switch back or re-authenticate anytime.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Log Out'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (context.mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      await UserService.instance.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeUser = UserService.instance.currentUser;
    final isCloud = activeUser?.isCloudLinked ?? false;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle pill
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: AppTheme.dividerColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),

            // Sheet Top Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 14, 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryPurpleLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(CupertinoIcons.person_2_fill,
                        color: AppTheme.primaryPurple, size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Switch Profile & Accounts',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                            letterSpacing: -0.3,
                          ),
                        ),
                        Text(
                          'Saved profiles on this device',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // "+ Add Account" button
                  TextButton.icon(
                    onPressed: () => _navigateToAddProfile(context),
                    icon: const Icon(CupertinoIcons.plus, size: 14),
                    label: const Text(
                      'Add',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.primaryPurple,
                      backgroundColor: AppTheme.primaryPurpleLight,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(CupertinoIcons.xmark,
                        size: 18, color: AppTheme.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: AppTheme.dividerColor),

            // Scrollable content: Profiles List & Session actions
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                children: [
                  // 1. Saved Profiles List
                  ValueListenableBuilder<List<UserProfile>>(
                    valueListenable: UserService.instance.profilesListNotifier,
                    builder: (context, profiles, _) {
                      return Column(
                        children: profiles.map((profile) {
                          final isActive = activeUser?.id == profile.id;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? AppTheme.primaryPurpleLight
                                      .withValues(alpha: 0.5)
                                  : AppTheme.surfaceWhite,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isActive
                                    ? AppTheme.primaryPurple
                                        .withValues(alpha: 0.35)
                                    : AppTheme.dividerColor,
                              ),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: isActive
                                    ? null
                                    : () => _handleSwitchProfile(
                                        context, profile.id),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  child: Row(
                                    children: [
                                      // Avatar (photo & emoji)
                                      UserAvatarWidget(
                                        user: profile,
                                        size: 42,
                                      ),
                                      const SizedBox(width: 12),

                                      // Name & Details
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    profile.name,
                                                    style: TextStyle(
                                                      fontWeight: isActive
                                                          ? FontWeight.w800
                                                          : FontWeight.w600,
                                                      fontSize: 14,
                                                      color:
                                                          AppTheme.textPrimary,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                if (isActive) ...[
                                                  const SizedBox(width: 6),
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 6,
                                                        vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: AppTheme
                                                          .primaryPurple,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              6),
                                                    ),
                                                    child: const Text(
                                                      'ACTIVE',
                                                      style: TextStyle(
                                                        fontSize: 9,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: Colors.white,
                                                        letterSpacing: 0.5,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              profile.isCloudLinked
                                                  ? (profile.email ??
                                                      'Cloud Linked')
                                                  : 'Local · Offline',
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                color: AppTheme.textMuted,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Active Checkmark
                                      if (isActive)
                                        Container(
                                          width: 24,
                                          height: 24,
                                          margin:
                                              const EdgeInsets.only(right: 6),
                                          decoration: BoxDecoration(
                                            color: AppTheme.primaryPurple
                                                .withValues(alpha: 0.15),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            CupertinoIcons.checkmark,
                                            size: 13,
                                            color: AppTheme.primaryPurple,
                                          ),
                                        ),

                                      // Dedicated Trash / Remove Icon Button
                                      IconButton(
                                        icon: const Icon(
                                          CupertinoIcons.trash,
                                          size: 16,
                                          color: Color(0xFFEF4444),
                                        ),
                                        tooltip: 'Remove Profile',
                                        padding: const EdgeInsets.all(6),
                                        constraints: const BoxConstraints(),
                                        splashRadius: 18,
                                        onPressed: () => _handleDeleteProfile(
                                            context, profile),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),

                  const SizedBox(height: 16),
                  const Divider(height: 1, color: AppTheme.dividerColor),
                  const SizedBox(height: 16),

                  // 2. Reset Local Cache (if cloud user)
                  if (isCloud) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: OutlinedButton.icon(
                        onPressed: () => _handleResetLocalCache(context),
                        icon: const Icon(Icons.refresh_rounded,
                            size: 16, color: AppTheme.textSecondary),
                        label: const Text(
                          'Reset Local Cache & Re-sync',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.dividerColor),
                          backgroundColor: AppTheme.surfaceWhite,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // 3. Log Out Account Button
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: TextButton.icon(
                      onPressed: () => _handleLogout(context),
                      icon: const Icon(
                        Icons.logout_rounded,
                        size: 16,
                        color: Color(0xFFDC2626),
                      ),
                      label: const Text(
                        'Log Out Account',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: Color(0xFFDC2626),
                        ),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFFFEF2F2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
