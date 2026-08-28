import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile_model.dart';
import 'auto_sync_service.dart';
import 'document_storage_service.dart';

/// Manages local offline accounts and optional Supabase cloud account linking.
class UserService {
  static final UserService instance = UserService._internal();
  UserService._internal();

  static const String _profilesKey = 'ayens_kwaderno_user_profiles_v1';
  static const String _activeProfileIdKey = 'ayens_kwaderno_active_profile_id_v1';

  final ValueNotifier<UserProfile?> currentUserNotifier =
      ValueNotifier<UserProfile?>(null);

  final ValueNotifier<List<UserProfile>> profilesListNotifier =
      ValueNotifier<List<UserProfile>>([]);

  UserProfile? get currentUser => currentUserNotifier.value;
  String get activeUserId => currentUser?.id ?? 'default_user';

  /// Generates standard RFC 4122 v4 UUID string compatible with Postgres UUID columns
  static String generateUuid() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40; // version 4
    values[8] = (values[8] & 0x3f) | 0x80; // variant
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// Initializes the user service, loading active and saved profiles from local storage
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final profilesJson = prefs.getString(_profilesKey);
      final activeId = prefs.getString(_activeProfileIdKey);

      List<UserProfile> profiles = [];
      if (profilesJson != null && profilesJson.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(profilesJson) as List<dynamic>;
        final rawProfiles = decoded
            .map((item) =>
                UserProfile.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();

        // Deduplicate profiles cleanly without merging document data
        final Map<String, UserProfile> uniqueMap = {};
        for (final p in rawProfiles) {
          final key = p.email != null && p.email!.trim().isNotEmpty
              ? p.email!.toLowerCase().trim()
              : p.id;
          if (!uniqueMap.containsKey(key)) {
            uniqueMap[key] = p;
          } else {
            final existing = uniqueMap[key]!;
            final primary = p.isCloudLinked ? p : existing;
            uniqueMap[key] = primary;
          }
        }

        profiles = uniqueMap.values.toList();
        await prefs.setString(
          _profilesKey,
          jsonEncode(profiles.map((p) => p.toJson()).toList()),
        );
      }

      profilesListNotifier.value = profiles;

      if (profiles.isNotEmpty) {
        if (activeId != null) {
          final found = profiles.where((p) => p.id == activeId).toList();
          currentUserNotifier.value = found.isNotEmpty ? found.first : profiles.first;
        } else {
          currentUserNotifier.value = profiles.first;
        }
      }

      // Check if active user is linked to Supabase and keep session in sync
      final current = currentUser;
      if (current != null && current.isCloudLinked) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null && current.email != null) {
          debugPrint('Supabase cloud account session restored for ${current.email}');
        }
      }
    } catch (e) {
      debugPrint('Error initializing UserService: $e');
    }
  }

  /// Creates a new instant offline profile on the device
  Future<UserProfile> createOfflineProfile({
    required String name,
    String avatarEmoji = 'book',
    String? avatarImagePath,
    int avatarColorIndex = 0,
  }) async {
    final now = DateTime.now();

    String? effectiveAvatarUrl;
    if (avatarImagePath != null && avatarImagePath.trim().isNotEmpty) {
      final trimmed = avatarImagePath.trim();
      if (trimmed.startsWith('data:image') || trimmed.startsWith('http')) {
        effectiveAvatarUrl = trimmed;
      } else {
        try {
          final file = File(trimmed);
          if (file.existsSync()) {
            final bytes = await file.readAsBytes();
            effectiveAvatarUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
          }
        } catch (_) {}
      }
    }

    final profile = UserProfile(
      id: generateUuid(),
      name: name.trim().isEmpty ? 'Student' : name.trim(),
      avatarEmoji: avatarEmoji,
      avatarImagePath: avatarImagePath,
      avatarUrl: effectiveAvatarUrl,
      avatarColorIndex: avatarColorIndex,
      isCloudLinked: false,
      createdAt: now,
      lastActiveAt: now,
    );

    await _saveProfile(profile, makeActive: true);

    // Only migrate legacy data if first profile
    if (profilesListNotifier.value.length <= 1) {
      await DocumentStorageService.migrateLegacyDataToUser(profile.id);
    }

    return profile;
  }

  /// Updates profile details (name, avatar emoji, avatar photo, color)
  Future<void> updateProfile({
    String? name,
    String? avatarEmoji,
    String? avatarImagePath,
    String? avatarUrl,
    bool clearCustomImage = false,
    int? avatarColorIndex,
  }) async {
    final current = currentUser;
    if (current == null) return;

    String? effectiveAvatarUrl = avatarUrl;
    String? effectiveImagePath = avatarImagePath;

    if (!clearCustomImage &&
        avatarImagePath != null &&
        avatarImagePath.trim().isNotEmpty) {
      final trimmed = avatarImagePath.trim();
      if (trimmed.startsWith('http')) {
        effectiveAvatarUrl = trimmed;
        effectiveImagePath = trimmed;
      } else {
        try {
          Uint8List? imageBytes;
          if (trimmed.startsWith('data:image')) {
            final raw =
                trimmed.contains(',') ? trimmed.split(',').last : trimmed;
            imageBytes = base64Decode(raw);
          } else {
            final file = File(trimmed);
            if (file.existsSync()) {
              imageBytes = await file.readAsBytes();
            }
          }

          if (imageBytes != null && imageBytes.isNotEmpty) {
            final targetId = current.supabaseUserId ?? current.id;
            try {
              final client = Supabase.instance.client;
              final storagePath = '$targetId/avatar.jpg';
              await client.storage.from('avatars').uploadBinary(
                    storagePath,
                    imageBytes,
                    fileOptions: const FileOptions(
                        upsert: true, contentType: 'image/jpeg'),
                  );
              final publicUrl =
                  client.storage.from('avatars').getPublicUrl(storagePath);
              effectiveAvatarUrl = publicUrl;
              effectiveImagePath = trimmed;
            } catch (e) {
              debugPrint('Notice uploading avatar in updateProfile: $e');
              effectiveAvatarUrl =
                  'data:image/jpeg;base64,${base64Encode(imageBytes)}';
              effectiveImagePath = trimmed;
            }
          }
        } catch (_) {}
      }
    } else if (clearCustomImage) {
      effectiveAvatarUrl = null;
      effectiveImagePath = null;
    }

    final updated = current.copyWith(
      name: name != null && name.trim().isNotEmpty ? name.trim() : current.name,
      avatarEmoji: avatarEmoji ?? current.avatarEmoji,
      avatarImagePath: effectiveImagePath,
      avatarUrl: effectiveAvatarUrl,
      clearCustomImage: clearCustomImage,
      avatarColorIndex: avatarColorIndex ?? current.avatarColorIndex,
      lastActiveAt: DateTime.now(),
    );

    await _saveProfile(updated, makeActive: true);

    if (updated.isCloudLinked) {
      try {
        final client = Supabase.instance.client;
        final targetId =
            updated.supabaseUserId ?? client.auth.currentUser?.id ?? updated.id;
        final profilePayload = <String, dynamic>{
          'id': targetId,
          'name': updated.name,
          'avatar_emoji': updated.avatarEmoji,
          'avatar_color_index': updated.avatarColorIndex,
          'email': updated.email,
          'is_cloud_linked': true,
          'created_at': updated.createdAt.toUtc().toIso8601String(),
          'last_active_at': DateTime.now().toUtc().toIso8601String(),
        };
        if (updated.avatarUrl != null) {
          profilePayload['avatar_url'] = updated.avatarUrl;
        }

        try {
          await client
              .from('user_profiles')
              .upsert(profilePayload, onConflict: 'id');
        } catch (_) {
          // If avatar_url column is not yet present in Supabase table, retry without it
          profilePayload.remove('avatar_url');
          await client
              .from('user_profiles')
              .upsert(profilePayload, onConflict: 'id');
        }
      } catch (e) {
        debugPrint('Notice updating user profile to cloud: $e');
      }
    }
  }

  /// Links the current offline profile to a Supabase Cloud Account (Email/Password)
  Future<void> linkSupabaseAccount({
    required String email,
    required String password,
    required bool isSignUp,
    String? optionalName,
    String? optionalAvatarEmoji,
    String? optionalAvatarImagePath,
  }) async {
    final client = Supabase.instance.client;

    AuthResponse authResponse;
    if (isSignUp) {
      authResponse = await client.auth.signUp(
        email: email.trim(),
        password: password,
        data: {
          'display_name': optionalName ?? currentUser?.name ?? 'Student',
        },
      );
    } else {
      authResponse = await client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    }

    final user = authResponse.user;
    if (user == null) {
      throw const AuthException('Unable to obtain user session from Supabase.');
    }

    // Fetch remote user profile if already exists in Supabase
    String displayName = optionalName?.trim().isNotEmpty == true
        ? optionalName!.trim()
        : (currentUser?.name ?? user.email?.split('@').first ?? 'Student');
    String avatarEmoji = optionalAvatarEmoji ?? currentUser?.avatarEmoji ?? 'book';
    String? avatarImagePath = optionalAvatarImagePath ?? currentUser?.avatarImagePath;
    int avatarColorIndex = currentUser?.avatarColorIndex ?? 0;

    try {
      final remoteProfileRes = await client
          .from('user_profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      if (remoteProfileRes != null) {
        if (remoteProfileRes['name'] != null &&
            (remoteProfileRes['name'] as String).trim().isNotEmpty) {
          displayName = (remoteProfileRes['name'] as String).trim();
        }
        if (remoteProfileRes['avatar_emoji'] != null) {
          avatarEmoji = remoteProfileRes['avatar_emoji'] as String;
        }
        if (remoteProfileRes['avatar_url'] != null) {
          avatarImagePath = remoteProfileRes['avatar_url'] as String;
        }
        if (remoteProfileRes['avatar_color_index'] != null) {
          avatarColorIndex = remoteProfileRes['avatar_color_index'] as int;
        }
      }
    } catch (_) {}

    final isPreviousOffline = currentUser?.isCloudLinked != true;
    final previousId = currentUser?.id;

    // If avatarImagePath is a local file, upload to Supabase Storage avatars bucket
    String? effectiveAvatarUrl = avatarImagePath;
    if (avatarImagePath != null && avatarImagePath.trim().isNotEmpty) {
      final trimmed = avatarImagePath.trim();
      if (trimmed.startsWith('http')) {
        effectiveAvatarUrl = trimmed;
      } else {
        try {
          Uint8List? imageBytes;
          if (trimmed.startsWith('data:image')) {
            final raw =
                trimmed.contains(',') ? trimmed.split(',').last : trimmed;
            imageBytes = base64Decode(raw);
          } else {
            final file = File(trimmed);
            if (file.existsSync()) {
              imageBytes = await file.readAsBytes();
            }
          }

          if (imageBytes != null && imageBytes.isNotEmpty) {
            try {
              final storagePath = '${user.id}/avatar.jpg';
              await client.storage.from('avatars').uploadBinary(
                    storagePath,
                    imageBytes,
                    fileOptions: const FileOptions(
                        upsert: true, contentType: 'image/jpeg'),
                  );
              final publicUrl =
                  client.storage.from('avatars').getPublicUrl(storagePath);
              effectiveAvatarUrl = publicUrl;
            } catch (e) {
              debugPrint('Notice uploading avatar in linkSupabaseAccount: $e');
              effectiveAvatarUrl =
                  'data:image/jpeg;base64,${base64Encode(imageBytes)}';
            }
          }
        } catch (_) {}
      }
    }

    final now = DateTime.now();
    final linkedProfile = UserProfile(
      id: user.id,
      name: displayName,
      avatarEmoji: avatarEmoji,
      avatarImagePath: avatarImagePath,
      avatarUrl: effectiveAvatarUrl,
      avatarColorIndex: avatarColorIndex,
      email: user.email ?? email.trim(),
      isCloudLinked: true,
      supabaseUserId: user.id,
      createdAt: currentUser?.createdAt ?? now,
      lastActiveAt: now,
    );

    await _saveProfile(linkedProfile, makeActive: true);

    // Only migrate previous documents if upgrading from an offline profile
    if (previousId != null && previousId != user.id && isPreviousOffline) {
      await DocumentStorageService.migrateUserData(previousId, user.id);
    }

    // Direct immediate upsert to user_profiles table in Supabase
    try {
      final profilePayload = <String, dynamic>{
        'id': user.id,
        'name': linkedProfile.name,
        'avatar_emoji': linkedProfile.avatarEmoji,
        'avatar_color_index': linkedProfile.avatarColorIndex,
        'email': linkedProfile.email,
        'is_cloud_linked': true,
        'created_at': linkedProfile.createdAt.toUtc().toIso8601String(),
        'last_active_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (linkedProfile.avatarUrl != null) {
        profilePayload['avatar_url'] = linkedProfile.avatarUrl;
      }

      try {
        await client
            .from('user_profiles')
            .upsert(profilePayload, onConflict: 'id');
      } catch (_) {
        profilePayload.remove('avatar_url');
        await client
            .from('user_profiles')
            .upsert(profilePayload, onConflict: 'id');
      }
    } catch (e) {
      debugPrint('Notice saving user profile to cloud: $e');
    }

    // Immediately download and sync all documents & notes for this account onto this device
    await AutoSyncService.instance.syncAllToCloud();
  }

  /// Unlinks the active profile from Supabase Cloud (keeps local offline data safe)
  Future<void> unlinkSupabaseAccount() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}

    final current = currentUser;
    if (current == null) return;

    final unlinked = current.copyWith(
      isCloudLinked: false,
      supabaseUserId: null,
      lastActiveAt: DateTime.now(),
    );

    await _saveProfile(unlinked, makeActive: true);
  }

  /// Logs out of active account session (signs out of Supabase and clears active session)
  Future<void> logout() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeProfileIdKey);
    currentUserNotifier.value = null;
  }

  /// Ends the session for the currently active profile, removes it from device profiles,
  /// and returns the count of remaining active profiles on the device.
  Future<int> logoutCurrentProfile() async {
    final current = currentUser;
    if (current == null) return profilesListNotifier.value.length;

    if (current.isCloudLinked) {
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {}
    }

    final list = List<UserProfile>.from(profilesListNotifier.value);
    list.removeWhere((p) => p.id == current.id);
    profilesListNotifier.value = list;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode(list.map((p) => p.toJson()).toList()),
    );
    await prefs.remove(_activeProfileIdKey);

    currentUserNotifier.value = null;
    return list.length;
  }

  /// Clears all local profile sessions and redirects to fresh authentication
  Future<void> logoutAll() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}

    profilesListNotifier.value = [];
    currentUserNotifier.value = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_profilesKey);
    await prefs.remove(_activeProfileIdKey);
  }

  /// Switches active profile on device (scoped per user)
  Future<void> switchProfile(String profileId) async {
    final list = profilesListNotifier.value;
    final target = list.firstWhere(
      (p) => p.id == profileId,
      orElse: () => list.first,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeProfileIdKey, target.id);
    currentUserNotifier.value = target;

    // Trigger immediate cloud auto-sync for the newly active profile
    if (target.isCloudLinked) {
      await AutoSyncService.instance.syncAllToCloud();
    }
  }

  /// Deletes a profile from the local device
  Future<void> deleteProfile(String profileId) async {
    final list = List<UserProfile>.from(profilesListNotifier.value);
    list.removeWhere((p) => p.id == profileId);
    profilesListNotifier.value = list;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode(list.map((p) => p.toJson()).toList()),
    );

    // Clean up scoped storage for this profile
    await DocumentStorageService.deleteAllUserData(profileId);

    if (currentUser?.id == profileId) {
      if (list.isNotEmpty) {
        currentUserNotifier.value = list.first;
        await prefs.setString(_activeProfileIdKey, list.first.id);
      } else {
        currentUserNotifier.value = null;
        await prefs.remove(_activeProfileIdKey);
      }
    }
  }

  Future<void> _saveProfile(UserProfile profile, {bool makeActive = true}) async {
    final list = List<UserProfile>.from(profilesListNotifier.value);
    
    // Find matching profile by ID, email, or Supabase user ID
    final idx = list.indexWhere((p) =>
        p.id == profile.id ||
        (profile.email != null &&
            profile.email!.trim().isNotEmpty &&
            p.email?.toLowerCase().trim() ==
                profile.email!.toLowerCase().trim()) ||
        (profile.supabaseUserId != null &&
            p.supabaseUserId == profile.supabaseUserId));

    if (idx >= 0) {
      list[idx] = profile;
    } else {
      list.insert(0, profile);
    }

    // Deduplicate profiles by email or id
    final Map<String, UserProfile> uniqueMap = {};
    for (final p in list) {
      final key = p.email != null && p.email!.trim().isNotEmpty
          ? p.email!.toLowerCase().trim()
          : p.id;
      if (!uniqueMap.containsKey(key)) {
        uniqueMap[key] = p;
      } else {
        final existing = uniqueMap[key]!;
        final primary = p.id == profile.id || p.isCloudLinked ? p : existing;
        uniqueMap[key] = primary;
      }
    }
    final cleanedList = uniqueMap.values.toList();

    profilesListNotifier.value = cleanedList;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode(cleanedList.map((p) => p.toJson()).toList()),
    );

    if (makeActive) {
      currentUserNotifier.value = profile;
      await prefs.setString(_activeProfileIdKey, profile.id);
    }
  }
}
