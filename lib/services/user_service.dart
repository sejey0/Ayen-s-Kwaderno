import 'dart:convert';
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

        // Clean up and deduplicate profiles by email or unique ID
        final Map<String, UserProfile> uniqueMap = {};
        for (final p in rawProfiles) {
          final key = p.email != null && p.email!.trim().isNotEmpty
              ? p.email!.toLowerCase().trim()
              : p.id;
          if (!uniqueMap.containsKey(key)) {
            uniqueMap[key] = p;
          } else {
            if (p.isCloudLinked) {
              uniqueMap[key] = p;
            }
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
    String avatarEmoji = '📓',
    int avatarColorIndex = 0,
  }) async {
    final now = DateTime.now();
    final profile = UserProfile(
      id: generateUuid(),
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
        final targetId = updated.supabaseUserId ?? client.auth.currentUser?.id ?? updated.id;
        final profilePayload = {
          'id': targetId,
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

    // Fetch remote user profile if already exists in Supabase
    String displayName = optionalName?.trim().isNotEmpty == true
        ? optionalName!.trim()
        : (currentUser?.name ?? user.email?.split('@').first ?? 'Student');
    String avatarEmoji = currentUser?.avatarEmoji ?? '📓';
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
        if (remoteProfileRes['avatar_color_index'] != null) {
          avatarColorIndex = remoteProfileRes['avatar_color_index'] as int;
        }
      }
    } catch (_) {}

    final now = DateTime.now();
    final linkedProfile = UserProfile(
      id: user.id,
      name: displayName,
      avatarEmoji: avatarEmoji,
      avatarColorIndex: avatarColorIndex,
      email: user.email ?? email.trim(),
      isCloudLinked: true,
      supabaseUserId: user.id,
      createdAt: currentUser?.createdAt ?? now,
      lastActiveAt: now,
    );

    await _saveProfile(linkedProfile, makeActive: true);

    // Direct immediate upsert to user_profiles table in Supabase
    try {
      final profilePayload = {
        'id': user.id,
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
        if (p.id == profile.id || p.isCloudLinked) {
          uniqueMap[key] = p;
        }
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
