import 'dart:convert';
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

  /// Initializes the user service, loading active and saved profiles from local storage
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final profilesJson = prefs.getString(_profilesKey);
      final activeId = prefs.getString(_activeProfileIdKey);

      List<UserProfile> profiles = [];
      if (profilesJson != null && profilesJson.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(profilesJson) as List<dynamic>;
        profiles = decoded
            .map((item) =>
                UserProfile.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
      }

      profilesListNotifier.value = profiles;

      if (profiles.isNotEmpty) {
        UserProfile active = profiles.first;
        if (activeId != null) {
          active = profiles.firstWhere(
            (p) => p.id == activeId,
            orElse: () => profiles.first,
          );
        }

        // Check if Supabase session exists and sync cloud link status
        UserProfile finalActive = active;
        try {
          final supabaseUser = Supabase.instance.client.auth.currentUser;
          if (supabaseUser != null && active.isCloudLinked) {
            finalActive = active.copyWith(
              supabaseUserId: supabaseUser.id,
              email: supabaseUser.email ?? active.email,
            );
          }
        } catch (_) {}

        currentUserNotifier.value = finalActive;
        await prefs.setString(_activeProfileIdKey, finalActive.id);
      } else {
        currentUserNotifier.value = null;
      }
    } catch (e) {
      debugPrint('UserService init error: $e');
    }
  }

  /// Creates a new instant offline profile on the device
  Future<UserProfile> createOfflineProfile({
    required String name,
    String avatarEmoji = '📓',
    int avatarColorIndex = 0,
  }) async {
    final now = DateTime.now();
    final profile = UserProfile(
      id: 'user_${now.millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Student' : name.trim(),
      avatarEmoji: avatarEmoji,
      avatarColorIndex: avatarColorIndex,
      isCloudLinked: false,
      createdAt: now,
      lastActiveAt: now,
    );

    await _saveProfile(profile, makeActive: true);

    // Automatically migrate legacy documents & notes to this profile if first time
    await DocumentStorageService.migrateLegacyDataToUser(profile.id);

    return profile;
  }

  /// Updates profile details (name, avatar, color)
  Future<void> updateProfile({
    String? name,
    String? avatarEmoji,
    int? avatarColorIndex,
  }) async {
    final current = currentUser;
    if (current == null) return;

    final updated = current.copyWith(
      name: name != null && name.trim().isNotEmpty ? name.trim() : current.name,
      avatarEmoji: avatarEmoji ?? current.avatarEmoji,
      avatarColorIndex: avatarColorIndex ?? current.avatarColorIndex,
      lastActiveAt: DateTime.now(),
    );

    await _saveProfile(updated, makeActive: true);

    if (updated.isCloudLinked) {
      try {
        final client = Supabase.instance.client;
        final profilePayload = {
          'id': updated.id,
          'name': updated.name,
          'avatar_emoji': updated.avatarEmoji,
          'avatar_color_index': updated.avatarColorIndex,
          'email': updated.email,
          'is_cloud_linked': true,
          'created_at': updated.createdAt.toUtc().toIso8601String(),
          'last_active_at': DateTime.now().toUtc().toIso8601String(),
        };
        await client
            .from('user_profiles')
            .upsert(profilePayload, onConflict: 'id');
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

    final current = currentUser;
    UserProfile linkedProfile;

    if (current != null) {
      linkedProfile = current.copyWith(
        email: user.email ?? email.trim(),
        isCloudLinked: true,
        supabaseUserId: user.id,
        name: optionalName != null && optionalName.trim().isNotEmpty
            ? optionalName.trim()
            : current.name,
        lastActiveAt: DateTime.now(),
      );
    } else {
      // Direct cloud signup without existing profile
      final now = DateTime.now();
      linkedProfile = UserProfile(
        id: 'user_${now.millisecondsSinceEpoch}',
        name: optionalName?.trim().isNotEmpty == true
            ? optionalName!.trim()
            : (user.email?.split('@').first ?? 'Student'),
        email: user.email ?? email.trim(),
        isCloudLinked: true,
        supabaseUserId: user.id,
        createdAt: now,
        lastActiveAt: now,
      );
    }

    await _saveProfile(linkedProfile, makeActive: true);

    // Direct immediate upsert to user_profiles table in Supabase
    try {
      final profilePayload = {
        'id': linkedProfile.id,
        'name': linkedProfile.name,
        'avatar_emoji': linkedProfile.avatarEmoji,
        'avatar_color_index': linkedProfile.avatarColorIndex,
        'email': linkedProfile.email,
        'is_cloud_linked': true,
        'created_at': linkedProfile.createdAt.toUtc().toIso8601String(),
        'last_active_at': DateTime.now().toUtc().toIso8601String(),
      };
      await client
          .from('user_profiles')
          .upsert(profilePayload, onConflict: 'id');
    } catch (e) {
      debugPrint('Notice saving user profile to cloud: $e');
    }

    // Trigger instant cloud sync for all notes and documents
    AutoSyncService.instance.triggerSync(immediate: true);
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

    // Trigger sync for the newly active profile if cloud-linked
    if (target.isCloudLinked) {
      AutoSyncService.instance.triggerSync(immediate: true);
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
    final idx = list.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      list[idx] = profile;
    } else {
      list.insert(0, profile);
    }

    profilesListNotifier.value = list;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode(list.map((p) => p.toJson()).toList()),
    );

    if (makeActive) {
      currentUserNotifier.value = profile;
      await prefs.setString(_activeProfileIdKey, profile.id);
    }
  }
}
