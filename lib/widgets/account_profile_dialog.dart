import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/user_profile_model.dart';
import '../screens/welcome_auth_screen.dart';
import '../services/auto_sync_service.dart';
import '../services/document_storage_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';

/// Legacy entry point maintained for compatibility across the app.
/// Opens the dedicated full-screen [ProfileSettingsScreen].
class AccountProfileDialog extends StatelessWidget {
  const AccountProfileDialog({super.key});

  static Future<void> show(BuildContext context) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (context) => const ProfileSettingsScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// =============================================================================
// FULL-SCREEN PROFILE SETTINGS SCREEN
// =============================================================================

class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  bool _isEditingProfile = false;
  bool _isSyncing = false;

  late TextEditingController _nameController;
  late String _currentEmoji;

  static const List<String> _avatarEmojis = [
    '📓',
    '✍️',
    '🎒',
    '🌸',
    '⚡',
    '🎨',
    '🎓',
    '🌟',
    '💡',
    '🐾',
    '📚',
    '🧸',
  ];

  @override
  void initState() {
    super.initState();
    final user = UserService.instance.currentUser;
    _nameController = TextEditingController(text: user?.name ?? 'Student');
    _currentEmoji = user?.avatarEmoji ?? '📓';
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // ACTIONS
  // ===========================================================================

  Future<void> _handleSaveProfile() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    await UserService.instance.updateProfile(
      name: name,
      avatarEmoji: _currentEmoji,
    );

    if (mounted) {
      setState(() => _isEditingProfile = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(CupertinoIcons.checkmark_seal_fill,
                  color: Color(0xFF10B981), size: 16),
              SizedBox(width: 8),
              Text('Profile updated successfully! ✨',
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

  Future<void> _handleSyncNow() async {
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
              Text('Sync complete! All notes up to date ⚡',
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

  Future<void> _handleUnlinkCloud() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Unlink Cloud Account?'),
        content: const Text(
          'Your local notes will remain completely safe on this device. Cloud auto-sync will be paused.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Unlink'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await UserService.instance.unlinkSupabaseAccount();
      if (mounted) setState(() {});
    }
  }

  /// Dynamic Logout Routing Logic
  Future<void> _handleLogout() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Log Out of Account?'),
        content: const Text(
          'Are you sure you want to log out? Your notes and documents remain safely stored in your cloud account.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Log Out'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      // Ends active session for this profile and dynamically routes
      await UserService.instance.logoutCurrentProfile();
    }
  }

  Future<void> _handleDeleteProfile(UserProfile targetProfile) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('Remove Profile "${targetProfile.name}"?'),
        content: const Text(
          'This will remove this profile from this device. Cloud-synced data remains safe in your cloud account.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Remove'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await UserService.instance.deleteProfile(targetProfile.id);
      if (!mounted) return;
      if (UserService.instance.currentUser == null) {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      } else {
        setState(() {});
      }
    }
  }

  Future<void> _handleResetLocalCache() async {
    final user = UserService.instance.currentUser;
    if (user == null) return;

    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Reset Local Cache?'),
        content: const Text(
          'This will clear local device files for this profile and re-download fresh data from the cloud.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Reset Cache'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await DocumentStorageService.deleteAllUserData(user.id);
      await AutoSyncService.instance.syncAllToCloud();
      UserService.instance.currentUserNotifier.value = user;
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Local cache reset for ${user.name}. Fresh cloud sync complete.'),
          backgroundColor: const Color(0xFF2E7D32),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _handleSwitchProfile(String profileId) async {
    await UserService.instance.switchProfile(profileId);
    if (mounted) {
      final user = UserService.instance.currentUser;
      _nameController.text = user?.name ?? 'Student';
      _currentEmoji = user?.avatarEmoji ?? '📓';
      _isEditingProfile = false;
      setState(() {});
    }
  }

  /// Navigates directly to the Main Login / Sign-Up Page with Cancel capability
  void _navigateToAddProfile() {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (context) => const WelcomeAuthScreen(canCancel: true),
      ),
    );
  }

  // ===========================================================================
  // MAIN BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return ValueListenableBuilder<UserProfile?>(
      valueListenable: UserService.instance.currentUserNotifier,
      builder: (context, user, _) {
        if (user == null) {
          return const Scaffold(
            backgroundColor: AppTheme.background,
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        final isCloud = user.isCloudLinked;

        return Scaffold(
          backgroundColor: AppTheme.background,
          body: CustomScrollView(
            slivers: [
              // ── TOP NAVIGATION BAR ──
              SliverAppBar(
                pinned: true,
                backgroundColor: AppTheme.surfaceWhite,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 1,
                leading: IconButton(
                  icon: const Icon(CupertinoIcons.back,
                      color: AppTheme.textPrimary, size: 22),
                  onPressed: () {
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
                title: const Text(
                  'Profile Settings',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                centerTitle: true,
                actions: [
                  if (_isEditingProfile)
                    TextButton(
                      onPressed: _handleSaveProfile,
                      child: const Text(
                        'Save',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: AppTheme.primaryPurple,
                        ),
                      ),
                    ),
                ],
              ),

              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, bottomPadding + 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 1. ACTIVE PROFILE HEADER ──
                      _buildActiveProfileHeader(user),

                      const SizedBox(height: 14),

                      // ── 2. INLINE EDIT PROFILE (when active) ──
                      if (_isEditingProfile) ...[
                        _buildEditProfileCard(),
                        const SizedBox(height: 14),
                      ],

                      // ── 3. CLOUD STATUS CARD ──
                      _buildCloudStatusCard(user, isCloud),

                      const SizedBox(height: 24),

                      // ── 4. SWITCH PROFILE & ACCOUNTS ──
                      _buildSwitchProfilesSection(user),

                      const SizedBox(height: 32),

                      // ── 5. SESSION MANAGEMENT & DANGER ZONE ──
                      _buildSessionManagementSection(user, isCloud),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ===========================================================================
  // 1. ACTIVE PROFILE HEADER
  // ===========================================================================

  Widget _buildActiveProfileHeader(UserProfile user) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.dividerColor),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryPurple.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Circular Gradient Avatar
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryPurple.withValues(alpha: 0.28),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Center(
              child: Text(
                user.avatarEmoji,
                style: const TextStyle(fontSize: 30),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Name and Registered Email
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.name,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: user.isCloudLinked
                            ? const Color(0xFF10B981)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        user.isCloudLinked
                            ? (user.email ?? 'Cloud Synced')
                            : 'Offline · Local Storage',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: user.isCloudLinked
                              ? const Color(0xFF065F46)
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Subtle Profile Edit Action Button
          GestureDetector(
            onTap: () {
              if (_isEditingProfile) {
                _handleSaveProfile();
              } else {
                setState(() => _isEditingProfile = true);
              }
            },
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _isEditingProfile
                    ? AppTheme.primaryPurple
                    : AppTheme.primaryPurpleLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _isEditingProfile
                    ? CupertinoIcons.checkmark
                    : CupertinoIcons.pencil,
                size: 16,
                color: _isEditingProfile
                    ? Colors.white
                    : AppTheme.primaryPurple,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 2. INLINE EDIT PROFILE CARD
  // ===========================================================================

  Widget _buildEditProfileCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Display Name',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              hintText: 'Enter name',
              filled: true,
              fillColor: AppTheme.background,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.dividerColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppTheme.primaryPurple, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Choose Avatar',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _avatarEmojis.map((emoji) {
                final isSel = emoji == _currentEmoji;
                return GestureDetector(
                  onTap: () => setState(() => _currentEmoji = emoji),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 44,
                    height: 44,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: isSel
                          ? AppTheme.primaryPurpleLight
                          : AppTheme.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSel
                            ? AppTheme.primaryPurple
                            : AppTheme.dividerColor,
                        width: isSel ? 2 : 1,
                      ),
                    ),
                    child: Center(
                      child: Text(emoji, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 3. CLOUD STATUS CARD
  // ===========================================================================

  Widget _buildCloudStatusCard(UserProfile user, bool isCloud) {
    if (isCloud) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF10B981).withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(CupertinoIcons.checkmark_shield_fill,
                      color: Color(0xFF10B981), size: 18),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Cloud Backup Active ✨',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                      color: Color(0xFF065F46),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                // Balanced "Sync Now" Button
                Expanded(
                  child: SizedBox(
                    height: 38,
                    child: OutlinedButton.icon(
                      onPressed: _isSyncing ? null : _handleSyncNow,
                      icon: _isSyncing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFF10B981)),
                            )
                          : const Icon(CupertinoIcons.refresh, size: 14),
                      label: Text(
                        _isSyncing ? 'Syncing...' : 'Sync Now',
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF10B981)),
                        foregroundColor: const Color(0xFF065F46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Balanced "Unlink Cloud" Button
                Expanded(
                  child: SizedBox(
                    height: 38,
                    child: TextButton.icon(
                      onPressed: _handleUnlinkCloud,
                      icon: const Icon(Icons.link_off_rounded,
                          size: 15, color: AppTheme.textMuted),
                      label: const Text(
                        'Unlink Cloud',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    } else {
      // Connect Cloud Card
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surfaceWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.dividerColor),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppTheme.primaryPurpleLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(CupertinoIcons.cloud_upload_fill,
                  color: AppTheme.primaryPurple, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Link Cloud Backup',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Keep notes backed up and synced safely',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            ElevatedButton(
              onPressed: _navigateToAddProfile,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryPurple,
                foregroundColor: Colors.white,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('Connect',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
    }
  }

  // ===========================================================================
  // 4. SWITCH PROFILE & ACCOUNTS SECTION
  // ===========================================================================

  Widget _buildSwitchProfilesSection(UserProfile activeUser) {
    return ValueListenableBuilder<List<UserProfile>>(
      valueListenable: UserService.instance.profilesListNotifier,
      builder: (context, profiles, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section Title with "+ Add Profile" action button
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Switch Profile & Accounts',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _navigateToAddProfile,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryPurpleLight,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.plus,
                            size: 13, color: AppTheme.primaryPurple),
                        SizedBox(width: 4),
                        Text(
                          'Add Profile',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryPurple,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Profile List Cards
            ...profiles.map((p) {
              final isActive = p.id == activeUser.id;
              return _buildProfileItemCard(p, isActive);
            }),
          ],
        );
      },
    );
  }

  Widget _buildProfileItemCard(UserProfile profile, bool isActive) {
    return GestureDetector(
      onTap: isActive ? null : () => _handleSwitchProfile(profile.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.primaryPurpleLight.withValues(alpha: 0.5)
              : AppTheme.surfaceWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive
                ? AppTheme.primaryPurple.withValues(alpha: 0.35)
                : AppTheme.dividerColor,
          ),
        ),
        child: Row(
          children: [
            // Emoji Avatar Container
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isActive
                    ? AppTheme.primaryPurple.withValues(alpha: 0.12)
                    : AppTheme.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(profile.avatarEmoji,
                    style: const TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(width: 12),
            // Profile Name & Status
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
                    style: TextStyle(
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 14,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profile.isCloudLinked
                        ? (profile.email ?? '☁️ Cloud Linked')
                        : '📱 Local · Offline',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            // Active Checkmark or Delete Icon
            if (isActive)
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: AppTheme.primaryPurple,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(CupertinoIcons.checkmark,
                    size: 14, color: Colors.white),
              )
            else
              GestureDetector(
                onTap: () => _handleDeleteProfile(profile),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(CupertinoIcons.trash,
                      size: 13, color: Color(0xFFEF4444)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 5. DANGER ZONE & SESSION ACTIONS
  // ===========================================================================

  Widget _buildSessionManagementSection(UserProfile user, bool isCloud) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Subtle neutral divider
        Container(
          height: 1,
          color: AppTheme.dividerColor,
        ),
        const SizedBox(height: 20),

        // "Reset Local Cache & Re-sync": Secondary outlined button
        if (isCloud) ...[
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton.icon(
              onPressed: _handleResetLocalCache,
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

        // "Log Out Account": Primary red action button
        SizedBox(
          width: double.infinity,
          height: 46,
          child: TextButton.icon(
            onPressed: _handleLogout,
            icon: const Icon(
              Icons.logout_rounded,
              size: 17,
              color: Color(0xFFDC2626),
            ),
            label: const Text(
              'Log Out Account',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
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
    );
  }
}
