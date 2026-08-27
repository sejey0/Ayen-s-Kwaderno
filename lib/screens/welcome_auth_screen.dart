import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

enum AuthMode {
  offline,
  cloudSignIn,
  cloudSignUp,
}

class WelcomeAuthScreen extends StatefulWidget {
  const WelcomeAuthScreen({super.key});

  @override
  State<WelcomeAuthScreen> createState() => _WelcomeAuthScreenState();
}

class _WelcomeAuthScreenState extends State<WelcomeAuthScreen> {
  AuthMode _mode = AuthMode.offline;

  // Offline form controllers
  final TextEditingController _nameController = TextEditingController(text: 'Ayen');
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

  /// Creates instant offline account & navigates to Home
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

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
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

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
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
        _errorMessage = 'Authentication failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = _mode == AuthMode.offline;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // App Logo / Avatar Badge
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primaryPurple.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      isOffline ? _selectedEmoji : '☁️',
                      style: const TextStyle(fontSize: 38),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // App Title & Tagline
                const Text(
                  "Ayen's Kwaderno",
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Smart offline notebook with AI handwriting & cloud sync",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: AppTheme.textSecondary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 24),

                // Mode Switcher Tabs (Offline vs Cloud)
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.dividerColor),
                    boxShadow: AppTheme.softShadow,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildSegmentButton(
                          title: 'Offline Notebook',
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
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Form Container
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppTheme.dividerColor),
                    boxShadow: AppTheme.softShadow,
                  ),
                  child: isOffline
                      ? _buildOfflineForm()
                      : _buildCloudAuthForm(),
                ),

                const SizedBox(height: 20),

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
                            color: Color(0xFFEF4444), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFFDC2626),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Quick Note / Footer
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(CupertinoIcons.lock_shield_fill,
                        size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 6),
                    Text(
                      isOffline
                          ? "100% offline & private on this device"
                          : "Encrypted & synced with Supabase",
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
        duration: const Duration(milliseconds: 200),
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
              size: 16,
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
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          "Set up your local notebook space. You can link to cloud anytime later.",
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),

        // Name input
        const Text(
          "Your Name / Nickname",
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: "e.g. Ayen, Juan, Maria...",
            prefixIcon: const Icon(CupertinoIcons.person_fill,
                color: AppTheme.primaryPurple, size: 18),
            filled: true,
            fillColor: AppTheme.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppTheme.dividerColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppTheme.dividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                  color: AppTheme.primaryPurple, width: 1.8),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 16),

        // Emoji avatar selection
        const Text(
          "Choose Notebook Avatar",
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: _avatarEmojis.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, idx) {
              final emoji = _avatarEmojis[idx];
              final isSelected = emoji == _selectedEmoji;
              return GestureDetector(
                onTap: () => setState(() => _selectedEmoji = emoji),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 46,
                  height: 46,
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
                      style: const TextStyle(fontSize: 22),
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
          "Choose Theme Color",
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
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
        const SizedBox(height: 24),

        // Start Button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _handleStartOffline,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
              foregroundColor: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Start Notebook Offline",
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                      SizedBox(width: 8),
                      Icon(CupertinoIcons.arrow_right_circle_fill, size: 20),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// Supabase Cloud Account Sign In / Sign Up Form
  Widget _buildCloudAuthForm() {
    final isSignUp = _mode == AuthMode.cloudSignUp;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              isSignUp ? "Create Cloud Account" : "Sign In to Cloud",
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  _mode = isSignUp ? AuthMode.cloudSignIn : AuthMode.cloudSignUp;
                  _errorMessage = null;
                });
              },
              child: Text(
                isSignUp ? "Have an account? Sign In" : "Need account? Sign Up",
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryPurple,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isSignUp
              ? "Register with Supabase to backup notes across devices."
              : "Sign in with your email to restore your cloud notebook.",
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),

        // Optional Name if Sign Up
        if (isSignUp) ...[
          const Text(
            "Full Name",
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _cloudNameController,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: "e.g. Ayen",
              prefixIcon: const Icon(CupertinoIcons.person_fill,
                  color: AppTheme.primaryPurple, size: 18),
              filled: true,
              fillColor: AppTheme.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppTheme.dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppTheme.dividerColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(
                    color: AppTheme.primaryPurple, width: 1.8),
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
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            hintText: "name@example.com",
            prefixIcon: const Icon(CupertinoIcons.mail_solid,
                color: AppTheme.primaryPurple, size: 18),
            filled: true,
            fillColor: AppTheme.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppTheme.dividerColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppTheme.dividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                  color: AppTheme.primaryPurple, width: 1.8),
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
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            hintText: "••••••••",
            prefixIcon: const Icon(CupertinoIcons.lock_fill,
                color: AppTheme.primaryPurple, size: 18),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? CupertinoIcons.eye_slash_fill
                    : CupertinoIcons.eye_fill,
                color: AppTheme.textSecondary,
                size: 18,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
            filled: true,
            fillColor: AppTheme.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppTheme.dividerColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppTheme.dividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                  color: AppTheme.primaryPurple, width: 1.8),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 24),

        // Cloud Action Button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _handleCloudAuth,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
              foregroundColor: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
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
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isSignUp
                            ? "Create Cloud Account"
                            : "Sign In & Sync Notebook",
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
