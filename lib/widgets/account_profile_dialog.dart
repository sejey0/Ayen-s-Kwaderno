import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile_model.dart';
import '../services/auto_sync_service.dart';
import '../services/document_storage_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';

class AccountProfileDialog extends StatefulWidget {
  const AccountProfileDialog({super.key});

  static Future<void> show(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const AccountProfileDialog(),
    );
  }

  @override
  State<AccountProfileDialog> createState() => _AccountProfileDialogState();
}

class _AccountProfileDialogState extends State<AccountProfileDialog> {
  bool _isLinkingCloud = false;
  bool _isSignUpMode = false;
  bool _isEditingProfile = false;
  bool _isLoading = false;
  String? _errorMessage;

  // Cloud form controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  // Edit profile controller
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
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleLinkCloud() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage = 'Please enter a valid email address');
      return;
    }
    if (password.length < 6) {
      setState(
          () => _errorMessage = 'Password must be at least 6 characters long');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await UserService.instance.linkSupabaseAccount(
        email: email,
        password: password,
        isSignUp: _isSignUpMode,
      );

      if (!mounted) return;
      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(CupertinoIcons.checkmark_seal_fill,
                  color: Color(0xFF10B981), size: 18),
              SizedBox(width: 8),
              Text(
                'Signed in! All documents & notes synced ☁️✨',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          backgroundColor: AppTheme.primaryPurpleDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Cloud linking error: $e';
      });
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
      Navigator.pop(context); // Close bottom sheet
      await UserService.instance.logout();
    }
  }

  Future<void> _handleDeleteProfile(UserProfile targetProfile) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('Remove Profile "${targetProfile.name}"?'),
        content: const Text(
          'This will remove this profile and its local cached notes from this device. Cloud-synced data remains safe in your cloud account.',
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
        Navigator.pop(context);
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
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('Local cache reset for ${user.name}. Fresh cloud sync complete.'),
          backgroundColor: const Color(0xFF2E7D32),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _handleSaveProfile() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    await UserService.instance.updateProfile(
      name: name,
      avatarEmoji: _currentEmoji,
    );

    if (mounted) {
      setState(() => _isEditingProfile = false);
    }
  }

  Future<void> _showAddProfileDialog() async {
    final addController = TextEditingController();
    String emoji = '🎒';

    await showCupertinoDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => CupertinoAlertDialog(
          title: const Text('New Student Profile'),
          content: Column(
            children: [
              const SizedBox(height: 8),
              const Text('Add another offline notebook space to this device.'),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: addController,
                placeholder: 'Student Name (e.g. Maria)',
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _avatarEmojis.map((e) {
                    final isSel = e == emoji;
                    return GestureDetector(
                      onTap: () => setDialogState(() => emoji = e),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSel
                              ? AppTheme.primaryPurpleLight
                              : Colors.transparent,
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(context),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              child: const Text('Create Profile'),
              onPressed: () async {
                final name = addController.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(context);
                  await UserService.instance.createOfflineProfile(
                    name: name,
                    avatarEmoji: emoji,
                  );
                  if (mounted) setState(() {});
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UserProfile?>(
      valueListenable: UserService.instance.currentUserNotifier,
      builder: (context, user, _) {
        if (user == null) {
          return const SizedBox.shrink();
        }

        final isCloud = user.isCloudLinked;

        return Container(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
            top: 20,
            left: 20,
            right: 20,
          ),
          decoration: const BoxDecoration(
            color: AppTheme.surfaceWhite,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Modal Drag Handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // Top Profile Banner
                Row(
                  children: [
                    // Avatar Circle
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                AppTheme.primaryPurple.withValues(alpha: 0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          user.avatarEmoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
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
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isCloud
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFF94A3B8),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  isCloud
                                      ? (user.email ?? 'Cloud Synced')
                                      : 'Offline Account (Local Storage)',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: isCloud
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
                    IconButton(
                      icon: Icon(
                        _isEditingProfile
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.pencil_circle,
                        color: AppTheme.primaryPurple,
                        size: 26,
                      ),
                      tooltip: _isEditingProfile ? 'Save' : 'Edit Profile',
                      onPressed: () {
                        if (_isEditingProfile) {
                          _handleSaveProfile();
                        } else {
                          setState(() => _isEditingProfile = true);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // Inline Profile Editor
                if (_isEditingProfile) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.dividerColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Edit Name',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            hintText: 'Enter name',
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide:
                                  const BorderSide(color: AppTheme.dividerColor),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Choose Avatar',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _avatarEmojis.map((emoji) {
                              final isSel = emoji == _currentEmoji;
                              return GestureDetector(
                                onTap: () =>
                                    setState(() => _currentEmoji = emoji),
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 2),
                                  decoration: BoxDecoration(
                                    color: isSel
                                        ? AppTheme.primaryPurpleLight
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(emoji,
                                      style: const TextStyle(fontSize: 22)),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // ==========================================
                // CLOUD ACCOUNT STATUS & LINK CARD
                // ==========================================
                if (!isCloud) ...[
                  if (!_isLinkingCloud)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppTheme.primaryPurpleLight.withValues(alpha: 0.7),
                            AppTheme.accentPinkLight.withValues(alpha: 0.5),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(CupertinoIcons.cloud_upload_fill,
                                  color: AppTheme.primaryPurple, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Link Supabase Cloud Backup',
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Back up your documents, drawings, and converted notes so they are always safe and available across devices.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () =>
                                  setState(() => _isLinkingCloud = true),
                              icon: const Icon(CupertinoIcons.link, size: 16),
                              label: const Text(
                                'Connect Cloud Account',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryPurple,
                                foregroundColor: Colors.white,
                                elevation: 2,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    // In-modal Cloud Linking Form
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppTheme.dividerColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _isSignUpMode
                                    ? 'Create Cloud Account'
                                    : 'Sign In with Supabase',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              GestureDetector(
                                onTap: () => setState(() {
                                  _isSignUpMode = !_isSignUpMode;
                                  _errorMessage = null;
                                }),
                                child: Text(
                                  _isSignUpMode ? 'Sign In' : 'Sign Up',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                    color: AppTheme.primaryPurple,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              hintText: 'Email address',
                              prefixIcon: const Icon(CupertinoIcons.mail_solid,
                                  size: 16, color: AppTheme.primaryPurple),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide:
                                    const BorderSide(color: AppTheme.dividerColor),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            decoration: InputDecoration(
                              hintText: 'Password',
                              prefixIcon: const Icon(CupertinoIcons.lock_fill,
                                  size: 16, color: AppTheme.primaryPurple),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? CupertinoIcons.eye_slash
                                      : CupertinoIcons.eye,
                                  size: 16,
                                ),
                                onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword),
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide:
                                    const BorderSide(color: AppTheme.dividerColor),
                              ),
                            ),
                          ),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _errorMessage!,
                              style: const TextStyle(
                                  color: Color(0xFFEF4444), fontSize: 11.5),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () =>
                                    setState(() => _isLinkingCloud = false),
                                child: const Text('Cancel'),
                              ),
                              const Spacer(),
                              ElevatedButton(
                                onPressed: _isLoading ? null : _handleLinkCloud,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryPurple,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Text(
                                        _isSignUpMode ? 'Sign Up' : 'Link Now',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700),
                                      ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ] else ...[
                  // Cloud Connected Status Box
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF10B981).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Icon(CupertinoIcons.checkmark_seal_fill,
                                color: Color(0xFF10B981), size: 22),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Cloud Backup Active ✨',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      color: Color(0xFF065F46),
                                    ),
                                  ),
                                  Text(
                                    user.email ?? 'Synced with Supabase',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF047857),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  AutoSyncService.instance
                                      .triggerSync(immediate: true);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Auto-sync triggered! ⚡'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                },
                                icon: const Icon(CupertinoIcons.refresh, size: 14),
                                label: const Text('Sync Now',
                                    style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                      color: Color(0xFF10B981)),
                                  foregroundColor: const Color(0xFF065F46),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextButton.icon(
                                onPressed: _handleUnlinkCloud,
                                icon: const Icon(Icons.link_off_rounded,
                                    size: 16, color: AppTheme.textMuted),
                                label: const Text(
                                  'Unlink Cloud',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // ==========================================
                // SWITCH PROFILES SECTION (Multi-user per device)
                // ==========================================
                ValueListenableBuilder<List<UserProfile>>(
                  valueListenable: UserService.instance.profilesListNotifier,
                  builder: (context, profiles, _) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Device Profiles',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            GestureDetector(
                              onTap: _showAddProfileDialog,
                              child: const Row(
                                children: [
                                  Icon(CupertinoIcons.plus_circle_fill,
                                      size: 14, color: AppTheme.primaryPurple),
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
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...profiles.map((p) {
                          final isActive = p.id == user.id;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? AppTheme.primaryPurpleLight
                                  : AppTheme.background,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isActive
                                    ? AppTheme.primaryPurple
                                    : AppTheme.dividerColor,
                              ),
                            ),
                            child: Row(
                              children: [
                                Text(p.avatarEmoji,
                                    style: const TextStyle(fontSize: 18)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.name,
                                        style: TextStyle(
                                          fontWeight: isActive
                                              ? FontWeight.w800
                                              : FontWeight.w600,
                                          fontSize: 13,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      Text(
                                        p.isCloudLinked
                                            ? '☁️ Cloud Linked'
                                            : '📱 Offline',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isActive)
                                  const Icon(
                                      CupertinoIcons.checkmark_alt_circle_fill,
                                      color: AppTheme.primaryPurple,
                                      size: 18)
                                else
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: () {
                                          UserService.instance
                                              .switchProfile(p.id);
                                        },
                                        child: const Text('Switch',
                                            style: TextStyle(fontSize: 12)),
                                      ),
                                      IconButton(
                                        icon: const Icon(CupertinoIcons.trash,
                                            size: 16,
                                            color: Color(0xFFEF4444)),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () =>
                                            _handleDeleteProfile(p),
                                        tooltip: 'Remove Profile',
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          );
                        }),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 24),

                // ==========================================
                // DEDICATED LOGOUT / REMOVE CURRENT PROFILE CARD
                // ==========================================
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFFCA5A5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.logout_rounded,
                              color: Color(0xFFDC2626), size: 18),
                          const SizedBox(width: 8),
                          Text(
                            isCloud
                                ? 'Account Session'
                                : 'Active Profile Management',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: Color(0xFF991B1B),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isCloud
                            ? 'Logging out will sign you out of this device. Your notes and documents remain safely stored in your cloud account.'
                            : 'Removing this profile will delete its local notes cache from this device.',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFB91C1C),
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (isCloud) ...[
                        SizedBox(
                          width: double.infinity,
                          height: 38,
                          child: OutlinedButton.icon(
                            onPressed: _handleResetLocalCache,
                            icon: const Icon(
                              Icons.refresh_rounded,
                              size: 15,
                              color: Color(0xFF6B7280),
                            ),
                            label: const Text(
                              'Reset Local Cache & Re-sync',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: Color(0xFF374151),
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFD1D5DB)),
                              backgroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      SizedBox(
                        width: double.infinity,
                        height: 42,
                        child: OutlinedButton.icon(
                          onPressed: isCloud
                              ? _handleLogout
                              : () => _handleDeleteProfile(user),
                          icon: Icon(
                            isCloud
                                ? Icons.logout_rounded
                                : CupertinoIcons.trash,
                            size: 16,
                            color: const Color(0xFFDC2626),
                          ),
                          label: Text(
                            isCloud
                                ? 'Log Out Account'
                                : 'Remove Profile from Device',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: Color(0xFFDC2626),
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFDC2626)),
                            backgroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }
}
