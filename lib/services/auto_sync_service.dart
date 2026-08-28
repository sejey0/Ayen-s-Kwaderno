import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
      final hasNet = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn);

      if (hasNet) {
        debugPrint('[AutoSync] Device is ONLINE. Triggering auto-upload...');
        triggerSync();
      } else {
        debugPrint('[AutoSync] Device is OFFLINE. Queuing local updates...');
        statusNotifier.value = AutoSyncStatus.offline;
      }
    });

    // 2. Periodic sync heartbeat (every 2 minutes) to quietly push queued changes
    _periodicHeartbeatTimer =
        Timer.periodic(const Duration(minutes: 2), (_) {
      triggerSync(isSilent: true);
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
  void triggerSync({bool immediate = false, bool isSilent = false}) {
    if (immediate) {
      _debounceTimer?.cancel();
      syncAllToCloud(isSilent: isSilent);
    } else {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 1500), () {
        syncAllToCloud(isSilent: isSilent);
      });
    }
  }

  /// Performs full bi-directional sync: uploads all local pending documents, annotations,
  /// and handwriting notes to Supabase, and merges remote changes.
  Future<void> syncAllToCloud({bool isSilent = false}) async {
    if (_isSyncing) return;

    final user = UserService.instance.currentUser;
    final isAuthUser = Supabase.instance.client.auth.currentUser != null;
    final isCloudActive = user != null || isAuthUser;

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

    // If no active user, mark synced locally
    if (!isCloudActive) {
      statusNotifier.value = AutoSyncStatus.synced;
      return;
    }

    _isSyncing = true;
    if (!isSilent) {
      statusNotifier.value = AutoSyncStatus.syncing;
    }

    try {
      final client = Supabase.instance.client;
      final activeUserId = UserService.instance.activeUserId;

      // -------------------------------------------------------------
      // 0. AUTO-UPLOAD / SYNC USER PROFILE TO SUPABASE
      // -------------------------------------------------------------
      if (user != null) {
        try {
          final targetId =
              user.supabaseUserId ?? client.auth.currentUser?.id ?? user.id;

          // Check if remote profile has avatar_url or updated details from another phone
          try {
            final remoteProfile = await client
                .from('user_profiles')
                .select()
                .eq('id', targetId)
                .maybeSingle();

            if (remoteProfile != null) {
              final remoteAvatar = remoteProfile['avatar_url'] as String?;
              final remoteName = remoteProfile['name'] as String?;
              final remoteEmoji = remoteProfile['avatar_emoji'] as String?;
              final remoteColor = remoteProfile['avatar_color_index'] as int?;

              if (remoteAvatar != null &&
                  remoteAvatar.isNotEmpty &&
                  remoteAvatar != user.avatarUrl) {
                await UserService.instance.updateProfile(
                  name: remoteName,
                  avatarEmoji: remoteEmoji,
                  avatarImagePath: remoteAvatar,
                  avatarUrl: remoteAvatar,
                  avatarColorIndex: remoteColor,
                );
              }
            }
          } catch (_) {}

          final profilePayload = <String, dynamic>{
            'id': targetId,
            'name': user.name,
            'avatar_emoji': user.avatarEmoji,
            'avatar_color_index': user.avatarColorIndex,
            'email': user.email,
            'is_cloud_linked': user.isCloudLinked,
            'created_at': user.createdAt.toUtc().toIso8601String(),
            'last_active_at': DateTime.now().toUtc().toIso8601String(),
          };
          if (user.avatarUrl != null) {
            profilePayload['avatar_url'] = user.avatarUrl;
          }
          await client
              .from('user_profiles')
              .upsert(profilePayload, onConflict: 'id');
        } catch (e) {
          debugPrint('Notice user profile cloud sync status: $e');
        }
      }

      final userPrefix = 'u_${activeUserId}___';

      // -------------------------------------------------------------
      // 1. FETCH REMOTE DOCUMENT ANNOTATIONS & NOTE STROKES FROM SUPABASE
      // -------------------------------------------------------------
      final Map<String, List<dynamic>> noteStrokesMap = {};
      final List<DocumentItem> cloudDocs = [];
      final localDocs =
          await DocumentStorageService.loadSavedDocuments(activeUserId);

      try {
        final annotationsResponse = await client
            .from('document_annotations')
            .select()
            .timeout(const Duration(seconds: 10));

        for (final row in annotationsResponse) {
          final rawDocName = row['document_name'] as String?;
          if (rawDocName == null || !rawDocName.startsWith(userPrefix)) continue;

          final docName = rawDocName.substring(userPrefix.length);
          if (docName.isEmpty) continue;

          // If this is a note's drawing strokes:
          if (docName.startsWith('note_')) {
            final noteId = docName.substring('note_'.length);
            if (row['strokes_data'] is List) {
              noteStrokesMap[noteId] = row['strokes_data'] as List<dynamic>;
            }
            continue;
          }

          // Otherwise, it's a document:
          final rawStrokes = row['strokes_data'];
          final rawTexts = row['texts_data'];
          final rawImages = row['images_data'];

          Map<String, dynamic> strokesByPage = {};
          List<dynamic> flatStrokes = [];
          if (rawStrokes is Map) {
            strokesByPage = Map<String, dynamic>.from(rawStrokes);
            flatStrokes = strokesByPage.values
                .expand((e) => e is List ? e : [])
                .toList();
          } else if (rawStrokes is List) {
            flatStrokes = rawStrokes;
            strokesByPage['1'] = rawStrokes;
          }

          Map<String, dynamic> textsByPage = {};
          List<dynamic> flatTexts = [];
          if (rawTexts is Map) {
            textsByPage = Map<String, dynamic>.from(rawTexts);
            flatTexts = textsByPage.values
                .expand((e) => e is List ? e : [])
                .toList();
          } else if (rawTexts is List) {
            flatTexts = rawTexts;
            textsByPage['1'] = rawTexts;
          }

          Map<String, dynamic> imagesByPage = {};
          List<dynamic> flatImages = [];
          if (rawImages is Map) {
            imagesByPage = Map<String, dynamic>.from(rawImages);
            flatImages = imagesByPage.values
                .expand((e) => e is List ? e : [])
                .toList();
          } else if (rawImages is List) {
            flatImages = rawImages;
            imagesByPage['1'] = rawImages;
          }

          final totalAnnotations =
              flatStrokes.length + flatTexts.length + flatImages.length;
          final cloudUpdatedAt = row['updated_at'] != null
              ? DateTime.tryParse(row['updated_at'] as String)?.toLocal() ??
                  DateTime.now()
              : DateTime.now();

          // Immediately write cloud annotations into local SharedPreferences so they persist offline & on new devices
          try {
            final localData = {
              'strokes': flatStrokes.isNotEmpty
                  ? flatStrokes
                  : (strokesByPage['1'] is List ? strokesByPage['1'] : []),
              'texts': flatTexts.isNotEmpty
                  ? flatTexts
                  : (textsByPage['1'] is List ? textsByPage['1'] : []),
              'images': flatImages.isNotEmpty
                  ? flatImages
                  : (imagesByPage['1'] is List ? imagesByPage['1'] : []),
              'strokes_by_page': strokesByPage,
              'texts_by_page': textsByPage,
              'images_by_page': imagesByPage,
              'updated_at': row['updated_at'] ??
                  DateTime.now().toUtc().toIso8601String(),
            };

            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(
              'ayens_kwaderno_annot_u_${activeUserId}_$docName',
              jsonEncode(localData),
            );
          } catch (_) {}

          // Check if local file exists, or auto-download from Supabase Storage
          String? localFilePath;
          final localDocIndex =
              localDocs.indexWhere((d) => d.fileName == docName);
          if (localDocIndex >= 0 &&
              localDocs[localDocIndex].filePath != null &&
              File(localDocs[localDocIndex].filePath!).existsSync()) {
            localFilePath = localDocs[localDocIndex].filePath;
          } else {
            // Check saved_documents directory or download from cloud
            try {
              final appDir = await getApplicationDocumentsDirectory();
              final savedDocsDir = Directory('${appDir.path}/saved_documents');
              if (!savedDocsDir.existsSync()) {
                savedDocsDir.createSync(recursive: true);
              }
              final localFile = File('${savedDocsDir.path}/$docName');
              if (localFile.existsSync()) {
                localFilePath = localFile.path;
              } else {
                // Download file binary from Supabase Storage
                final storagePath = 'u_$activeUserId/$docName';
                Uint8List? fileBytes;
                try {
                  fileBytes = await client.storage
                      .from('documents')
                      .download(storagePath);
                } catch (_) {
                  try {
                    fileBytes = await client.storage
                      .from('user_documents')
                      .download(storagePath);
                  } catch (_) {}
                }
                if (fileBytes != null && fileBytes.isNotEmpty) {
                  await localFile.writeAsBytes(fileBytes);
                  localFilePath = localFile.path;
                }
              }
            } catch (_) {}
          }

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
      // 2. FETCH REMOTE HANDWRITTEN NOTES FROM SUPABASE & ATTACH STROKES
      // -------------------------------------------------------------
      final List<HandwritingNote> cloudNotes = [];
      try {
        final notesResponse = await client
            .from('handwriting_notes')
            .select()
            .order('updated_at', ascending: false)
            .timeout(const Duration(seconds: 10));

        for (final row in notesResponse) {
          final rawId = row['id'] as String? ?? '';
          if (!rawId.startsWith(userPrefix)) continue;
          final cleanId = rawId.substring(userPrefix.length);
          final map = Map<String, dynamic>.from(row);
          map['id'] = cleanId;

          final strokes = noteStrokesMap[cleanId];
          List<Map<String, dynamic>>? castedStrokes;
          if (strokes != null && strokes.isNotEmpty) {
            castedStrokes = strokes
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            map['strokes_json'] = castedStrokes;
            map['is_handwritten'] = true;
          }

          cloudNotes.add(
            HandwritingNote.fromJson(map).copyWith(
              isCloudSynced: true,
              strokesJson: castedStrokes,
              isHandwritten: castedStrokes != null && castedStrokes.isNotEmpty,
            ),
          );
        }
      } catch (e) {
        debugPrint('Notice fetching remote notes: $e');
      }

      // -------------------------------------------------------------
      // 3. RESOLVE NOTES & UPLOAD ONLY NEW OFFLINE ITEMS
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
      // 4. RESOLVE DOCUMENTS & UPLOAD ONLY NEW OFFLINE ITEMS
      // -------------------------------------------------------------
      final Set<String> cloudDocNames = cloudDocs.map((d) => d.fileName).toSet();
      final List<DocumentItem> finalDocs = List.from(cloudDocs);

      for (final local in localDocs) {
        if (!cloudDocNames.contains(local.fileName) && !local.isCloudSynced) {
          // Newly created offline doc: upload document metadata & binary to Supabase
          try {
            final annotationsData =
                await DocumentStorageService.loadLocalAnnotations(
                    local.fileName, activeUserId);
            final remoteDocName = '$userPrefix${local.fileName}';
            final payload = {
              'document_name': remoteDocName,
              'strokes_data': annotationsData?['strokes'] ?? [],
              'texts_data': annotationsData?['texts'] ?? [],
              'images_data': annotationsData?['images'] ?? [],
              'updated_at': annotationsData?['updated_at'] ??
                  DateTime.now().toUtc().toIso8601String(),
            };
            await client
                .from('document_annotations')
                .upsert(payload, onConflict: 'document_name');

            // Upload document file binary to Supabase Storage (if <= 50MB)
            if (local.filePath != null && File(local.filePath!).existsSync()) {
              final file = File(local.filePath!);
              final fileSize = await file.length();
              const maxUploadLimit = 50 * 1024 * 1024; // 50 MB

              if (fileSize <= maxUploadLimit) {
                final fileBytes = await file.readAsBytes();
                final storagePath = 'u_$activeUserId/${local.fileName}';
                try {
                  await client.storage.from('documents').uploadBinary(
                        storagePath,
                        fileBytes,
                        fileOptions: const FileOptions(upsert: true),
                      );
                } catch (_) {
                  try {
                    await client.storage.from('user_documents').uploadBinary(
                          storagePath,
                          fileBytes,
                          fileOptions: const FileOptions(upsert: true),
                        );
                  } catch (_) {}
                }
              }
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
