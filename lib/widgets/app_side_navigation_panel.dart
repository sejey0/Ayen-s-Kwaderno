import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/user_profile_model.dart';
import '../services/auto_sync_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import 'account_profile_dialog.dart';

enum SidebarNavItem {
  dashboard,
  documents,
  notes,
  settings,
  aiOcr,
  archive,
  help,
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
              Text('Cloud sync complete! ⚡',
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
    if (widget.isDrawerMode && widget.onCloseDrawer != null) {
      widget.onCloseDrawer!();
    }
    AccountProfileDialog.show(context);
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

                  // Section 2: Tools & Creation
                  if (_isExpanded) _buildSectionHeader('TOOLS & CREATION'),
                  _buildNavItem(
                    item: SidebarNavItem.aiOcr,
                    icon: CupertinoIcons.wand_rays_inverse,
                    label: 'AI Handwriting OCR',
                    badge: 'AI ✨',
                    badgeColor: AppTheme.primaryPurple,
                  ),

                  const SizedBox(height: 14),

                  // Section 3: Account & System (Sole Settings Entry Point)
                  if (_isExpanded) _buildSectionHeader('ACCOUNT & SYSTEM'),
                  _buildNavItem(
                    item: SidebarNavItem.settings,
                    icon: CupertinoIcons.gear_alt_fill,
                    label: 'Profile & Accounts',
                    badge: 'Active',
                    badgeColor: const Color(0xFF10B981),
                    onOverrideTap: _openSettings,
                  ),
                  _buildNavItem(
                    item: SidebarNavItem.archive,
                    icon: CupertinoIcons.archivebox_fill,
                    label: 'Archive & Trash',
                    badge: null,
                  ),
                  _buildNavItem(
                    item: SidebarNavItem.help,
                    icon: CupertinoIcons.question_circle_fill,
                    label: 'Help & About',
                    badge: null,
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
        final emoji = user?.avatarEmoji ?? '📓';

        if (!_isExpanded && !widget.isDrawerMode) {
          // Collapsed Top View
          return Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Tooltip(
                message: '$displayName\n$emailText',
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [
                            AppTheme.primaryPurpleLight,
                            AppTheme.accentPinkLight
                          ],
                        ),
                        border: Border.all(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Center(
                        child: Text(emoji, style: const TextStyle(fontSize: 22)),
                      ),
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
          );
        }

        // Expanded Top Header (Profile info on left, Close X button on right)
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Row(
            children: [
              // Large Circular Avatar
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primaryPurple.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    emoji,
                    style: const TextStyle(fontSize: 22),
                  ),
                ),
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
                  color: isSelected
                      ? AppTheme.primaryPurpleLight
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  border: isSelected
                      ? Border.all(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                        )
                      : null,
                ),
                child: Center(
                  child: Icon(
                    icon,
                    size: 20,
                    color: isSelected
                        ? AppTheme.primaryPurple
                        : AppTheme.textSecondary,
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
              color: isSelected
                  ? AppTheme.primaryPurpleLight.withValues(alpha: 0.6)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? AppTheme.primaryPurple.withValues(alpha: 0.25)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: isSelected
                      ? AppTheme.primaryPurple
                      : AppTheme.textSecondary,
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
                      color: isSelected
                          ? AppTheme.primaryPurple
                          : AppTheme.textPrimary,
                      letterSpacing: -0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // Badge Tag
                if (badge != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
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
  // 3. FOOTER (Single Sync Button & Simple Version Text)
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
