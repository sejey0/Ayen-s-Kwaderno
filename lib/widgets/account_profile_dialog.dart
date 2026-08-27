import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/user_profile_model.dart';
import '../screens/welcome_auth_screen.dart';
import '../services/auto_sync_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';

/// Opens the dedicated full-screen [ProfileSettingsScreen].
/// Returns the [UserProfile] if the user edited profile, or null otherwise.
class AccountProfileDialog extends StatelessWidget {
  const AccountProfileDialog({super.key});

  static Future<UserProfile?> show(BuildContext context) async {
    return await Navigator.of(context).push<UserProfile>(
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
                  color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
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

          // User details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  user.isCloudLinked
                      ? (user.email ?? 'Cloud Synced')
                      : 'Offline Local Account',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // Edit Profile toggle
          IconButton(
            icon: Icon(
              _isEditingProfile
                  ? CupertinoIcons.xmark_circle_fill
                  : CupertinoIcons.pencil_circle_fill,
              size: 28,
              color: _isEditingProfile
                  ? AppTheme.textSecondary
                  : AppTheme.primaryPurple,
            ),
            tooltip: _isEditingProfile ? 'Close Edit' : 'Edit Profile',
            onPressed: () {
              setState(() {
                _isEditingProfile = !_isEditingProfile;
                if (_isEditingProfile) {
                  _nameController.text = user.name;
                  _currentEmoji = user.avatarEmoji;
                }
              });
            },
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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppTheme.primaryPurple.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryPurple.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
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
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _nameController,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Enter your display name',
              filled: true,
              fillColor: AppTheme.background,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.dividerColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                    color: AppTheme.primaryPurple, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Choose Avatar Emoji',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary,
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
                // "Sync Now" Button
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
                // "Unlink Cloud" Button
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
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
}
