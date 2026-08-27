import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
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

      // -------------------------------------------------------------
      // 0. AUTO-UPLOAD USER PROFILE TO SUPABASE
      // -------------------------------------------------------------
      if (user != null && user.isCloudLinked) {
        try {
          final profilePayload = {
            'id': user.id,
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
          debugPrint('Notice syncing user profile: $e');
        }
      }

      // -------------------------------------------------------------
      // 1. AUTO-UPLOAD ALL SAVED HANDWRITTEN & TYPED NOTES TO SUPABASE
      // -------------------------------------------------------------
      final localNotes = await DocumentStorageService.loadHandwritingNotes();
      for (final note in localNotes) {
        try {
          final payload = {
            'id': note.id,
            'title': note.title,
            'content': note.content,
            'palette_index': note.paletteIndex,
            'updated_at': note.updatedAt.toUtc().toIso8601String(),
            'created_at': note.createdAt.toUtc().toIso8601String(),
          };
          await client
              .from('handwriting_notes')
              .upsert(payload, onConflict: 'id');
        } catch (e) {
          debugPrint('Notice syncing note ${note.id}: $e');
        }
      }

      // -------------------------------------------------------------
      // 2. AUTO-UPLOAD ALL DOCUMENT ANNOTATIONS TO SUPABASE
      // -------------------------------------------------------------
      final localDocs = await DocumentStorageService.loadSavedDocuments();
      for (final doc in localDocs) {
        try {
          final annotationsData =
              await DocumentStorageService.loadLocalAnnotations(doc.fileName);
          if (annotationsData != null) {
            final payload = {
              'document_name': doc.fileName,
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
        } catch (e) {
          debugPrint('Notice syncing annotations for ${doc.fileName}: $e');
        }
      }

      // -------------------------------------------------------------
      // 3. FETCH & MERGE ANY REMOTE HANDWRITTEN NOTES FROM SUPABASE
      // -------------------------------------------------------------
      try {
        final notesResponse = await client
            .from('handwriting_notes')
            .select()
            .order('updated_at', ascending: false);

        final Map<String, HandwritingNote> noteMap = {
          for (var n in localNotes) n.id: n
        };

        for (final row in notesResponse) {
          final cloudNote =
              HandwritingNote.fromJson(Map<String, dynamic>.from(row))
                  .copyWith(isCloudSynced: true);

          final localNote = noteMap[cloudNote.id];
          if (localNote != null) {
            // Keep local strokes intact if cloud row has text only
            noteMap[cloudNote.id] = cloudNote.copyWith(
              isHandwritten:
                  cloudNote.isHandwritten || localNote.isHandwritten,
              strokesJson: cloudNote.strokesJson ?? localNote.strokesJson,
            );
          } else {
            noteMap[cloudNote.id] = cloudNote;
          }
        }

        final mergedNotes = noteMap.values.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

        for (final note in mergedNotes) {
          await DocumentStorageService.saveOrUpdateHandwritingNote(note,
              triggerCloudSync: false);
        }
      } catch (e) {
        debugPrint('Notice fetching remote notes: $e');
      }

      // -------------------------------------------------------------
      // 4. FETCH & MERGE ANY REMOTE ANNOTATIONS FROM SUPABASE
      // -------------------------------------------------------------
      try {
        final annotationsResponse =
            await client.from('document_annotations').select();

        final Map<String, DocumentItem> docMap = {
          for (var d in localDocs) d.fileName: d
        };

        for (final row in annotationsResponse) {
          final docName = row['document_name'] as String?;
          if (docName == null || docName.isEmpty) continue;

          final strokes = (row['strokes_data'] as List<dynamic>?) ?? [];
          final texts = (row['texts_data'] as List<dynamic>?) ?? [];
          final images = (row['images_data'] as List<dynamic>?) ?? [];
          final totalAnnotations =
              strokes.length + texts.length + images.length;
          final cloudUpdatedAt = row['updated_at'] != null
              ? DateTime.tryParse(row['updated_at'] as String)?.toLocal() ??
                  DateTime.now()
              : DateTime.now();

          if (docMap.containsKey(docName)) {
            final existing = docMap[docName]!;
            docMap[docName] = existing.copyWith(
              annotationsCount: totalAnnotations > 0
                  ? totalAnnotations
                  : existing.annotationsCount,
              lastOpenedAt: cloudUpdatedAt.isAfter(existing.lastOpenedAt)
                  ? cloudUpdatedAt
                  : existing.lastOpenedAt,
              isCloudSynced: true,
            );
          } else {
            docMap[docName] = DocumentItem(
              fileName: docName,
              lastOpenedAt: cloudUpdatedAt,
              annotationsCount: totalAnnotations,
              isCloudSynced: true,
              paletteIndex: 0,
            );
          }

          await DocumentStorageService.saveOrUpdateDocument(docMap[docName]!,
              triggerCloudSync: false);
        }
      } catch (e) {
        debugPrint('Notice fetching remote annotations: $e');
      }

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
