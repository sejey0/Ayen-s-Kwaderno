import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/document_item_model.dart';
import '../models/handwriting_note_model.dart';
import 'document_storage_service.dart';
import 'user_service.dart';

enum AutoSyncStatus {
  synced,
  syncing,
  offline,
  error,
}

/// Service that monitors online connectivity and automatically uploads & syncs
/// documents, handwritten notes, and annotations to the Supabase database whenever
/// an update occurs or when network connection is restored.
class AutoSyncService {
  static final AutoSyncService instance = AutoSyncService._internal();
  AutoSyncService._internal();

  final ValueNotifier<AutoSyncStatus> statusNotifier =
      ValueNotifier<AutoSyncStatus>(AutoSyncStatus.synced);
  final ValueNotifier<DateTime?> lastSyncTimeNotifier =
      ValueNotifier<DateTime?>(null);
  final ValueNotifier<int> pendingChangesCount = ValueNotifier<int>(0);

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _periodicHeartbeatTimer;
  Timer? _debounceTimer;
  bool _isSyncing = false;

  /// Initializes connectivity listeners and background sync loop
  void initialize() {
    _cancelSubscriptions();

    // 1. Listen for real-time network connectivity changes (offline -> online)
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      final isOnline = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn);

      if (isOnline) {
        debugPrint('🌐 [AutoSync] Device is ONLINE. Triggering auto-upload...');
        triggerSync(immediate: true);
      } else {
        debugPrint('📴 [AutoSync] Device is OFFLINE. Queuing local updates...');
        statusNotifier.value = AutoSyncStatus.offline;
      }
    });

    // 2. Periodic sync heartbeat (every 25 seconds) to push queued changes
    _periodicHeartbeatTimer =
        Timer.periodic(const Duration(seconds: 25), (_) {
      triggerSync();
    });

    // 3. Initial sync on launch
    triggerSync(immediate: true);
  }

  void _cancelSubscriptions() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _periodicHeartbeatTimer?.cancel();
    _periodicHeartbeatTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// Triggers an auto-upload sync. If [immediate] is false, debounces rapid updates.
  void triggerSync({bool immediate = false}) {
    if (immediate) {
      _debounceTimer?.cancel();
      syncAllToCloud();
    } else {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 1500), () {
        syncAllToCloud();
      });
    }
  }

  /// Performs full bi-directional sync: uploads all local pending documents, annotations,
  /// and handwriting notes to Supabase, and merges remote changes.
  Future<void> syncAllToCloud() async {
    if (_isSyncing) return;

    final user = UserService.instance.currentUser;
    final isAuthUser = Supabase.instance.client.auth.currentUser != null;
    final isCloudActive = (user?.isCloudLinked == true) || isAuthUser;

    // Check connectivity first
    try {
      final connectivityResults = await Connectivity().checkConnectivity();
      final isOnline = connectivityResults.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn);

      if (!isOnline) {
        statusNotifier.value = AutoSyncStatus.offline;
        return;
      }
    } catch (_) {
      // If connectivity check fails, continue and let Supabase network call verify
    }

    // If not online or not cloud enabled, mark synced locally
    if (!isCloudActive) {
      statusNotifier.value = AutoSyncStatus.synced;
      return;
    }

    _isSyncing = true;
    statusNotifier.value = AutoSyncStatus.syncing;

    try {
      final client = Supabase.instance.client;
      final activeUserId = UserService.instance.activeUserId;

      // -------------------------------------------------------------
      // 0. AUTO-UPLOAD USER PROFILE TO SUPABASE
      // -------------------------------------------------------------
      if (user != null && user.isCloudLinked) {
        try {
          final targetId =
              user.supabaseUserId ?? client.auth.currentUser?.id ?? user.id;
          final profilePayload = {
            'id': targetId,
            'name': user.name,
            'avatar_emoji': user.avatarEmoji,
            'avatar_color_index': user.avatarColorIndex,
            'email': user.email,
            'is_cloud_linked': user.isCloudLinked,
            'created_at': user.createdAt.toUtc().toIso8601String(),
            'last_active_at': DateTime.now().toUtc().toIso8601String(),
          };
          await client
              .from('user_profiles')
              .upsert(profilePayload, onConflict: 'id');
        } catch (e) {
          debugPrint('Notice user profile cloud sync status: $e');
        }
      }

      final userPrefix = 'u_${activeUserId}___';

      // -------------------------------------------------------------
      // 1. FETCH REMOTE HANDWRITTEN NOTES FROM SUPABASE
      // -------------------------------------------------------------
      final List<HandwritingNote> cloudNotes = [];
      try {
        final notesResponse = await client
            .from('handwriting_notes')
            .select()
            .order('updated_at', ascending: false);

        for (final row in notesResponse) {
          final rawId = row['id'] as String? ?? '';
          if (!rawId.startsWith(userPrefix)) continue;
          final cleanId = rawId.substring(userPrefix.length);
          final map = Map<String, dynamic>.from(row);
          map['id'] = cleanId;
          cloudNotes.add(
            HandwritingNote.fromJson(map).copyWith(isCloudSynced: true),
          );
        }
      } catch (e) {
        debugPrint('Notice fetching remote notes: $e');
      }

      // -------------------------------------------------------------
      // 2. RESOLVE NOTES & UPLOAD ONLY NEW OFFLINE ITEMS
      // -------------------------------------------------------------
      final localNotes =
          await DocumentStorageService.loadHandwritingNotes(activeUserId);
      final Set<String> cloudNoteIds = cloudNotes.map((n) => n.id).toSet();
      final List<HandwritingNote> finalNotes = List.from(cloudNotes);

      for (final local in localNotes) {
        if (!cloudNoteIds.contains(local.id) && !local.isCloudSynced) {
          // Newly created offline note: upload to Supabase
          try {
            final remoteNoteId = '$userPrefix${local.id}';
            final payload = {
              'id': remoteNoteId,
              'title': local.title,
              'content': local.content,
              'palette_index': local.paletteIndex,
              'updated_at': local.updatedAt.toUtc().toIso8601String(),
              'created_at': local.createdAt.toUtc().toIso8601String(),
            };
            await client
                .from('handwriting_notes')
                .upsert(payload, onConflict: 'id');

            if (local.strokesJson != null && local.strokesJson!.isNotEmpty) {
              try {
                await client.from('document_annotations').upsert({
                  'document_name': '${userPrefix}note_${local.id}',
                  'strokes_data': local.strokesJson,
                  'updated_at': local.updatedAt.toUtc().toIso8601String(),
                }, onConflict: 'document_name');
              } catch (_) {}
            }
            finalNotes.add(local.copyWith(isCloudSynced: true));
          } catch (e) {
            debugPrint('Notice uploading offline note ${local.id}: $e');
            finalNotes.add(local);
          }
        }
      }
      finalNotes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ayens_kwaderno_notes_u_$activeUserId',
        jsonEncode(finalNotes.map((n) => n.toJson()).toList()),
      );

      // -------------------------------------------------------------
      // 3. FETCH REMOTE DOCUMENT ANNOTATIONS FROM SUPABASE
      // -------------------------------------------------------------
      final List<DocumentItem> cloudDocs = [];
      final localDocs =
          await DocumentStorageService.loadSavedDocuments(activeUserId);
      try {
        final annotationsResponse =
            await client.from('document_annotations').select();

        for (final row in annotationsResponse) {
          final rawDocName = row['document_name'] as String?;
          if (rawDocName == null || !rawDocName.startsWith(userPrefix)) continue;

          final docName = rawDocName.substring(userPrefix.length);
          if (docName.isEmpty || docName.startsWith('note_')) continue;

          final strokes = (row['strokes_data'] is List)
              ? (row['strokes_data'] as List<dynamic>)
              : (row['strokes_data'] is Map
                  ? (row['strokes_data'] as Map)
                      .values
                      .expand((e) => e is List ? e : [])
                      .toList()
                  : []);
          final texts = (row['texts_data'] is List)
              ? (row['texts_data'] as List<dynamic>)
              : (row['texts_data'] is Map
                  ? (row['texts_data'] as Map)
                      .values
                      .expand((e) => e is List ? e : [])
                      .toList()
                  : []);
          final images = (row['images_data'] is List)
              ? (row['images_data'] as List<dynamic>)
              : (row['images_data'] is Map
                  ? (row['images_data'] as Map)
                      .values
                      .expand((e) => e is List ? e : [])
                      .toList()
                  : []);
          final totalAnnotations =
              strokes.length + texts.length + images.length;
          final cloudUpdatedAt = row['updated_at'] != null
              ? DateTime.tryParse(row['updated_at'] as String)?.toLocal() ??
                  DateTime.now()
              : DateTime.now();

          // Check if localDoc had a local file path
          final localDocIndex =
              localDocs.indexWhere((d) => d.fileName == docName);
          final localFilePath = localDocIndex >= 0
              ? localDocs[localDocIndex].filePath
              : null;

          cloudDocs.add(DocumentItem(
            fileName: docName,
            filePath: localFilePath,
            lastOpenedAt: cloudUpdatedAt,
            annotationsCount: totalAnnotations,
            isCloudSynced: true,
            paletteIndex: 0,
          ));
        }
      } catch (e) {
        debugPrint('Notice fetching remote annotations: $e');
      }

      // -------------------------------------------------------------
      // 4. RESOLVE DOCUMENTS & UPLOAD ONLY NEW OFFLINE ITEMS
      // -------------------------------------------------------------
      final Set<String> cloudDocNames = cloudDocs.map((d) => d.fileName).toSet();
      final List<DocumentItem> finalDocs = List.from(cloudDocs);

      for (final local in localDocs) {
        if (!cloudDocNames.contains(local.fileName) && !local.isCloudSynced) {
          // Newly created offline doc: upload annotations to Supabase
          try {
            final annotationsData =
                await DocumentStorageService.loadLocalAnnotations(
                    local.fileName, activeUserId);
            if (annotationsData != null) {
              final remoteDocName = '$userPrefix${local.fileName}';
              final payload = {
                'document_name': remoteDocName,
                'strokes_data': annotationsData['strokes'] ?? [],
                'texts_data': annotationsData['texts'] ?? [],
                'images_data': annotationsData['images'] ?? [],
                'updated_at': annotationsData['updated_at'] ??
                    DateTime.now().toUtc().toIso8601String(),
              };
              await client
                  .from('document_annotations')
                  .upsert(payload, onConflict: 'document_name');
            }
            finalDocs.add(local.copyWith(isCloudSynced: true));
          } catch (e) {
            debugPrint('Notice uploading offline doc ${local.fileName}: $e');
            finalDocs.add(local);
          }
        }
      }
      finalDocs.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));

      await prefs.setString(
        'ayens_kwaderno_docs_u_$activeUserId',
        jsonEncode(finalDocs.map((d) => d.toJson()).toList()),
      );

      statusNotifier.value = AutoSyncStatus.synced;
      lastSyncTimeNotifier.value = DateTime.now();
      pendingChangesCount.value = 0;
    } catch (e) {
      debugPrint('AutoSync error: $e');
      statusNotifier.value = AutoSyncStatus.error;
    } finally {
      _isSyncing = false;
    }
  }

  void dispose() {
    _cancelSubscriptions();
    statusNotifier.dispose();
    lastSyncTimeNotifier.dispose();
    pendingChangesCount.dispose();
  }
}
