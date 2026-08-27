import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auto_sync_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

enum AuthMode {
  cloudSignIn,
  cloudSignUp,
  offline,
}

class WelcomeAuthScreen extends StatefulWidget {
  final bool canCancel;

  const WelcomeAuthScreen({
    super.key,
    this.canCancel = false,
  });

  @override
  State<WelcomeAuthScreen> createState() => _WelcomeAuthScreenState();
}

class _WelcomeAuthScreenState extends State<WelcomeAuthScreen> {
  AuthMode _mode = AuthMode.cloudSignIn;

  // Offline form controllers
  final TextEditingController _nameController =
      TextEditingController(text: '');
  String _selectedEmoji = '📓';
  int _selectedColorIndex = 0;

  // Cloud auth form controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _cloudNameController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

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

  static const List<Color> _avatarColors = [
    AppTheme.primaryPurple,
    AppTheme.accentPink,
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFF8B5CF6),
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _cloudNameController.dispose();
    super.dispose();
  }

  void _onSuccessNavigate(String successMessage) {
    if (!mounted) return;

    if (widget.canCancel && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        CupertinoPageRoute(builder: (_) => const HomeScreen()),
      );
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(CupertinoIcons.checkmark_seal_fill,
                color: Color(0xFF10B981), size: 18),
            const SizedBox(width: 8),
            Text(
              successMessage,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        backgroundColor: AppTheme.primaryPurpleDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Creates instant offline account & completes flow
  Future<void> _handleStartOffline() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = 'Please enter your name or nickname');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await UserService.instance.createOfflineProfile(
        name: name,
        avatarEmoji: _selectedEmoji,
        avatarColorIndex: _selectedColorIndex,
      );

      _onSuccessNavigate('Offline profile "$name" created! 📓');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error setting up offline profile: $e';
      });
    }
  }

  /// Handles cloud sign in / sign up with Supabase
  Future<void> _handleCloudAuth() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _cloudNameController.text.trim();

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
        isSignUp: _mode == AuthMode.cloudSignUp,
        optionalName: name.isNotEmpty ? name : null,
      );

      _onSuccessNavigate('Signed in! Notes synced with cloud ☁️✨');
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
        _errorMessage = 'Authentication failed: $e';
      });
    }
  }

  /// Handles Google OAuth login
  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'io.supabase.ayenskwaderno://login-callback/',
      );
      await AutoSyncService.instance.syncAllToCloud();
      _onSuccessNavigate('Google account connected! ☁️');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Google sign-in error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = _mode == AuthMode.offline;
    final isSignUp = _mode == AuthMode.cloudSignUp;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surfaceWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        automaticallyImplyLeading: false,
        leading: widget.canCancel
            ? IconButton(
                icon: const Icon(CupertinoIcons.xmark,
                    color: AppTheme.textPrimary, size: 20),
                onPressed: () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
                tooltip: 'Cancel',
              )
            : null,
        title: Text(
          widget.canCancel ? 'Add New Profile' : "Ayen's Kwaderno",
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppTheme.textPrimary,
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 16, 20, bottomPadding + 24),
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // App Logo / Avatar Badge
                Container(
                  width: 72,
                  height: 72,
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
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      isOffline ? _selectedEmoji : '☁️',
                      style: const TextStyle(fontSize: 34),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Header Title & Tagline
                Text(
                  widget.canCancel
                      ? (isOffline
                          ? "Create Local Profile"
                          : (isSignUp
                              ? "Register Cloud Account"
                              : "Sign In to Cloud"))
                      : "Welcome to Kwaderno",
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isOffline
                      ? "Keep notes privately stored on this device"
                      : "Access & sync your notes across all your devices",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 20),

                // Mode Switcher Tabs (Cloud Account vs Offline Profile)
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.dividerColor),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primaryPurple.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildSegmentButton(
                          title: 'Cloud Account',
                          icon: CupertinoIcons.cloud_fill,
                          isSelected: !isOffline,
                          onTap: () {
                            setState(() {
                              _mode = AuthMode.cloudSignIn;
                              _errorMessage = null;
                            });
                          },
                        ),
                      ),
                      Expanded(
                        child: _buildSegmentButton(
                          title: 'Offline Profile',
                          icon: CupertinoIcons.device_phone_portrait,
                          isSelected: isOffline,
                          onTap: () {
                            setState(() {
                              _mode = AuthMode.offline;
                              _errorMessage = null;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // Form Container
                Container(
                  padding: const EdgeInsets.all(20),
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
                  child: isOffline
                      ? _buildOfflineForm()
                      : _buildCloudAuthForm(isSignUp),
                ),

                const SizedBox(height: 16),

                // Error Message Display
                if (_errorMessage != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(CupertinoIcons.exclamationmark_circle_fill,
                            color: Color(0xFFEF4444), size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFDC2626),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Security Badge / Footer
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(CupertinoIcons.lock_shield_fill,
                        size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 6),
                    Text(
                      isOffline
                          ? "100% offline & private on this device"
                          : "Encrypted & safely synced via Supabase",
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Segmented Switcher Tab Item
  Widget _buildSegmentButton({
    required String title,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primaryPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? Colors.white : AppTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? Colors.white : AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Instant Offline Profile Setup Form
  Widget _buildOfflineForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Student Profile",
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        const Text(
          "Create a dedicated offline notebook profile. No cloud connection required.",
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),

        // Name input
        const Text(
          "Student Name / Nickname",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: "e.g. Maria, Juan...",
            hintStyle: const TextStyle(color: AppTheme.textMuted),
            prefixIcon: const Icon(CupertinoIcons.person_fill,
                color: AppTheme.primaryPurple, size: 18),
            filled: true,
            fillColor: AppTheme.background,
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
              borderSide: const BorderSide(
                  color: AppTheme.primaryPurple, width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 16),

        // Emoji avatar selection
        const Text(
          "Choose Avatar Emoji",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: _avatarEmojis.length,
            separatorBuilder: (_, index) => const SizedBox(width: 8),
            itemBuilder: (context, idx) {
              final emoji = _avatarEmojis[idx];
              final isSelected = emoji == _selectedEmoji;
              return GestureDetector(
                onTap: () => setState(() => _selectedEmoji = emoji),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.primaryPurpleLight
                        : AppTheme.background,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? AppTheme.primaryPurple
                          : AppTheme.dividerColor,
                      width: isSelected ? 2.0 : 1.0,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      emoji,
                      style: const TextStyle(fontSize: 21),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),

        // Color theme selection
        const Text(
          "Choose Theme Accent",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(_avatarColors.length, (idx) {
            final color = _avatarColors[idx];
            final isSelected = idx == _selectedColorIndex;
            return GestureDetector(
              onTap: () => setState(() => _selectedColorIndex = idx),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? Colors.white : Colors.transparent,
                    width: 3,
                  ),
                  boxShadow: [
                    if (isSelected)
                      BoxShadow(
                        color: color.withValues(alpha: 0.5),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                  ],
                ),
                child: isSelected
                    ? const Icon(CupertinoIcons.checkmark,
                        color: Colors.white, size: 16)
                    : null,
              ),
            );
          }),
        ),
        const SizedBox(height: 22),

        // Start Button
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _handleStartOffline,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Create Offline Profile",
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                      SizedBox(width: 8),
                      Icon(CupertinoIcons.arrow_right_circle_fill, size: 18),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// Supabase Cloud Account Sign In / Sign Up Form
  Widget _buildCloudAuthForm(bool isSignUp) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              isSignUp ? "Create Cloud Account" : "Sign In to Cloud",
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  _mode =
                      isSignUp ? AuthMode.cloudSignIn : AuthMode.cloudSignUp;
                  _errorMessage = null;
                });
              },
              child: Text(
                isSignUp ? "Sign In instead" : "Create Account",
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryPurple,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          isSignUp
              ? "Register with email to backup notes across devices."
              : "Sign in with your email to restore your cloud notebook.",
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),

        // Optional Name if Sign Up
        if (isSignUp) ...[
          const Text(
            "Display Name",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _cloudNameController,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: "e.g. Ayen, CJay...",
              hintStyle: const TextStyle(color: AppTheme.textMuted),
              prefixIcon: const Icon(CupertinoIcons.person_fill,
                  color: AppTheme.primaryPurple, size: 18),
              filled: true,
              fillColor: AppTheme.background,
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
                borderSide: const BorderSide(
                    color: AppTheme.primaryPurple, width: 1.5),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 14),
        ],

        // Email input
        const Text(
          "Email Address",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            hintText: "name@example.com",
            hintStyle: const TextStyle(color: AppTheme.textMuted),
            prefixIcon: const Icon(CupertinoIcons.mail_solid,
                color: AppTheme.primaryPurple, size: 18),
            filled: true,
            fillColor: AppTheme.background,
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
              borderSide: const BorderSide(
                  color: AppTheme.primaryPurple, width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 14),

        // Password input
        const Text(
          "Password",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            hintText: "••••••••",
            hintStyle: const TextStyle(color: AppTheme.textMuted),
            prefixIcon: const Icon(CupertinoIcons.lock_fill,
                color: AppTheme.primaryPurple, size: 18),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? CupertinoIcons.eye_slash_fill
                    : CupertinoIcons.eye_fill,
                color: AppTheme.textMuted,
                size: 18,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
            filled: true,
            fillColor: AppTheme.background,
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
              borderSide: const BorderSide(
                  color: AppTheme.primaryPurple, width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 20),

        // Cloud Action Button
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _handleCloudAuth,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isSignUp
                            ? CupertinoIcons.sparkles
                            : CupertinoIcons.cloud_upload_fill,
                        size: 17,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isSignUp
                            ? "Create Cloud Account"
                            : "Sign In & Sync Notebook",
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
          ),
        ),

        const SizedBox(height: 14),

        // Divider with text
        Row(
          children: [
            Expanded(
                child: Container(height: 1, color: AppTheme.dividerColor)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('OR',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textMuted)),
            ),
            Expanded(
                child: Container(height: 1, color: AppTheme.dividerColor)),
          ],
        ),

        const SizedBox(height: 14),

        // Google Sign In Button
        SizedBox(
          width: double.infinity,
          height: 46,
          child: OutlinedButton.icon(
            onPressed: _isLoading ? null : _handleGoogleSignIn,
            icon: Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              child: const Text('G',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF4285F4))),
            ),
            label: const Text(
              'Continue with Google',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.dividerColor),
              backgroundColor: AppTheme.background,
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
