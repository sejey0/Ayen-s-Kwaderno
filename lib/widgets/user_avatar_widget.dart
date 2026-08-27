import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/user_profile_model.dart';
import '../theme/app_theme.dart';

/// Reusable, polished Avatar widget that supports:
/// - Real photo/images from device gallery/camera (Local file paths or Base64/Network URLs)
/// - Fallback emoji avatars with smooth gradient background
/// - Customizable size, radius, border, and edit badge
class UserAvatarWidget extends StatelessWidget {
  final UserProfile? user;
  final String? emoji;
  final String? imagePath;
  final double size;
  final double? fontSize;
  final bool showEditBadge;
  final VoidCallback? onEditTap;
  final VoidCallback? onTap;
  final BoxBorder? border;
  final List<Color>? gradientColors;

  const UserAvatarWidget({
    super.key,
    this.user,
    this.emoji,
    this.imagePath,
    this.size = 44,
    this.fontSize,
    this.showEditBadge = false,
    this.onEditTap,
    this.onTap,
    this.border,
    this.gradientColors,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveEmoji = emoji ?? user?.avatarEmoji ?? '📓';
    final effectiveImagePath = imagePath ?? user?.avatarImagePath ?? user?.avatarUrl;
    final effectiveFontSize = fontSize ?? (size * 0.48);

    final avatarContent = _buildAvatarContent(
      effectiveImagePath,
      effectiveEmoji,
      effectiveFontSize,
    );

    Widget avatarWidget = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: effectiveImagePath != null && effectiveImagePath.isNotEmpty
            ? null
            : LinearGradient(
                colors: gradientColors ??
                    const [AppTheme.primaryPurple, AppTheme.accentPink],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        color: effectiveImagePath != null && effectiveImagePath.isNotEmpty
            ? AppTheme.primaryPurpleLight
            : null,
        border: border ??
            Border.all(
              color: Colors.white,
              width: 1.5,
            ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryPurple.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipOval(
        child: avatarContent,
      ),
    );

    if (onTap != null) {
      avatarWidget = GestureDetector(
        onTap: onTap,
        child: avatarWidget,
      );
    }

    if (!showEditBadge) {
      return avatarWidget;
    }

    // Stack with camera / edit badge at bottom-right
    final badgeSize = (size * 0.32).clamp(20.0, 32.0);
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        avatarWidget,
        Positioned(
          right: 0,
          bottom: 0,
          child: GestureDetector(
            onTap: onEditTap ?? onTap,
            child: Container(
              width: badgeSize,
              height: badgeSize,
              decoration: BoxDecoration(
                color: AppTheme.primaryPurple,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                CupertinoIcons.camera_fill,
                size: badgeSize * 0.52,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarContent(
      String? path, String emoji, double emojiFontSize) {
    if (path != null && path.trim().isNotEmpty) {
      final cleanPath = path.trim();

      // Case 1: Base64 data string
      if (cleanPath.startsWith('data:image') || cleanPath.length > 500) {
        try {
          final rawBase64 = cleanPath.contains(',')
              ? cleanPath.split(',').last
              : cleanPath;
          final bytes = base64Decode(rawBase64);
          return Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _buildEmojiFallback(emoji, emojiFontSize),
          );
        } catch (_) {}
      }

      // Case 2: HTTP / HTTPS URL
      if (cleanPath.startsWith('http://') || cleanPath.startsWith('https://')) {
        return Image.network(
          cleanPath,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildEmojiFallback(emoji, emojiFontSize),
        );
      }

      // Case 3: Local File Path
      final file = File(cleanPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildEmojiFallback(emoji, emojiFontSize),
        );
      }
    }

    // Default: Emoji display
    return _buildEmojiFallback(emoji, emojiFontSize);
  }

  Widget _buildEmojiFallback(String emoji, double emojiFontSize) {
    return Center(
      child: Text(
        emoji,
        style: TextStyle(fontSize: emojiFontSize),
      ),
    );
  }
}
