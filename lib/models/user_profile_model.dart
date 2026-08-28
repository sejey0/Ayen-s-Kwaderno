import 'dart:convert';

/// Represents a local or cloud-linked user profile in Ayen's Kwaderno.
/// Allows per-user offline notebook storage with optional Supabase cloud account linking.
class UserProfile {
  final String id;
  final String name;
  final String avatarEmoji;
  final String? avatarImagePath;
  final String? avatarUrl;
  final int avatarColorIndex;
  final String? email;
  final bool isCloudLinked;
  final String? supabaseUserId;
  final DateTime createdAt;
  final DateTime lastActiveAt;

  const UserProfile({
    required this.id,
    required this.name,
    this.avatarEmoji = 'book',
    this.avatarImagePath,
    this.avatarUrl,
    this.avatarColorIndex = 0,
    this.email,
    this.isCloudLinked = false,
    this.supabaseUserId,
    required this.createdAt,
    required this.lastActiveAt,
  });

  /// Quick avatar initial letter (or uppercase first letter of name)
  String get initial =>
      name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'A';

  bool get hasCustomImage =>
      (avatarImagePath != null && avatarImagePath!.trim().isNotEmpty) ||
      (avatarUrl != null && avatarUrl!.trim().isNotEmpty);

  UserProfile copyWith({
    String? id,
    String? name,
    String? avatarEmoji,
    String? avatarImagePath,
    String? avatarUrl,
    bool clearCustomImage = false,
    int? avatarColorIndex,
    String? email,
    bool? isCloudLinked,
    String? supabaseUserId,
    DateTime? createdAt,
    DateTime? lastActiveAt,
  }) {
    return UserProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      avatarEmoji: avatarEmoji ?? this.avatarEmoji,
      avatarImagePath: clearCustomImage
          ? null
          : (avatarImagePath ?? this.avatarImagePath),
      avatarUrl:
          clearCustomImage ? null : (avatarUrl ?? this.avatarUrl),
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
      email: email ?? this.email,
      isCloudLinked: isCloudLinked ?? this.isCloudLinked,
      supabaseUserId: supabaseUserId ?? this.supabaseUserId,
      createdAt: createdAt ?? this.createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'avatar_emoji': avatarEmoji,
      'avatar_image_path': avatarImagePath,
      'avatar_url': avatarUrl ?? avatarImagePath,
      'avatar_color_index': avatarColorIndex,
      'email': email,
      'is_cloud_linked': isCloudLinked,
      'supabase_user_id': supabaseUserId,
      'created_at': createdAt.toIso8601String(),
      'last_active_at': lastActiveAt.toIso8601String(),
    };
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final imagePath = json['avatar_image_path'] as String? ??
        json['avatar_url'] as String?;
    final url = json['avatar_url'] as String? ??
        json['avatar_image_path'] as String?;

    return UserProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Student',
      avatarEmoji: json['avatar_emoji'] as String? ?? 'book',
      avatarImagePath: imagePath,
      avatarUrl: url,
      avatarColorIndex: json['avatar_color_index'] as int? ?? 0,
      email: json['email'] as String?,
      isCloudLinked: json['is_cloud_linked'] as bool? ?? false,
      supabaseUserId: json['supabase_user_id'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastActiveAt: json['last_active_at'] != null
          ? DateTime.tryParse(json['last_active_at'] as String) ??
              DateTime.now()
          : DateTime.now(),
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory UserProfile.fromJsonString(String str) =>
      UserProfile.fromJson(jsonDecode(str) as Map<String, dynamic>);
}
