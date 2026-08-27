import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/document_item_model.dart';
import '../models/handwriting_note_model.dart';
import '../models/image_annotation_model.dart';
import '../models/stroke_model.dart';
import '../models/text_annotation_model.dart';
import 'auto_sync_service.dart';
import 'user_service.dart';

/// Manages persistent local storage of recently opened/imported documents, annotations,
/// and handwriting notes scoped per user profile with automated real-time Supabase sync.
class DocumentStorageService {
  static const String _legacyDocumentsKey = 'ayens_kwaderno_recent_documents_v2';
  static const String _legacyHandwritingNotesKey =
      'ayens_kwaderno_handwriting_notes_v1';

  static String _getScopedDocumentsKey([String? userId]) {
    final uid = userId ?? UserService.instance.activeUserId;
    return 'ayens_kwaderno_docs_u_$uid';
  }

  static String _getScopedNotesKey([String? userId]) {
    final uid = userId ?? UserService.instance.activeUserId;
    return 'ayens_kwaderno_notes_u_$uid';
  }

  static String _getScopedAnnotationsKey(String documentName, [String? userId]) {
    final uid = userId ?? UserService.instance.activeUserId;
    return 'ayens_kwaderno_annot_u_${uid}_$documentName';
  }

  /// Migrates legacy un-scoped data from old keys to the given user profile ID
  static Future<void> migrateLegacyDataToUser(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Migrate documents
      final legacyDocsJson = prefs.getString(_legacyDocumentsKey);
      final userDocsKey = _getScopedDocumentsKey(userId);
      if (legacyDocsJson != null &&
          legacyDocsJson.isNotEmpty &&
          !prefs.containsKey(userDocsKey)) {
        await prefs.setString(userDocsKey, legacyDocsJson);
      }

      // 2. Migrate notes
      final legacyNotesJson = prefs.getString(_legacyHandwritingNotesKey);
      final userNotesKey = _getScopedNotesKey(userId);
      if (legacyNotesJson != null &&
          legacyNotesJson.isNotEmpty &&
          !prefs.containsKey(userNotesKey)) {
        await prefs.setString(userNotesKey, legacyNotesJson);
      }
    } catch (_) {}
  }

  /// Clears all local storage keys for a specific user ID
  static Future<void> deleteAllUserData(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_getScopedDocumentsKey(userId));
      await prefs.remove(_getScopedNotesKey(userId));
      final allKeys = prefs.getKeys();
      for (final key in allKeys) {
        if (key.startsWith('ayens_kwaderno_annot_u_${userId}_')) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  // ==========================================
  // DOCUMENT FILES PERSISTENCE
  // ==========================================

  /// Loads saved documents from SharedPreferences scoped strictly for the active user
  static Future<List<DocumentItem>> loadSavedDocuments([String? userId]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scopedKey = _getScopedDocumentsKey(userId);
      final String? jsonString = prefs.getString(scopedKey);

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final List<dynamic> decodedList = jsonDecode(jsonString) as List<dynamic>;
      final List<DocumentItem> docs = decodedList
          .map((item) =>
              DocumentItem.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

      // Sort newest first
      docs.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
      return docs;
    } catch (_) {
      return [];
    }
  }

  /// Saves or updates a document in persistent storage and triggers auto cloud sync
  static Future<void> saveOrUpdateDocument(
    DocumentItem doc, {
    bool triggerCloudSync = true,
    String? userId,
  }) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final docs = await loadSavedDocuments(targetUserId);

      // Remove existing entry by filename if any
      final existingIndex =
          docs.indexWhere((d) => d.fileName == doc.fileName);

      if (existingIndex >= 0) {
        final existing = docs[existingIndex];
        docs[existingIndex] = doc.copyWith(
          filePath: doc.filePath ?? existing.filePath,
          paletteIndex: existing.paletteIndex,
          annotationsCount: doc.annotationsCount > 0
              ? doc.annotationsCount
              : existing.annotationsCount,
          isCloudSynced: doc.isCloudSynced,
        );
      } else {
        docs.insert(0, doc);
      }

      // Keep max 50 recent documents per user
      if (docs.length > 50) {
        docs.removeRange(50, docs.length);
      }

      await _persistDocumentsList(docs, targetUserId);

      // Immediately push document annotations if available
      try {
        final client = Supabase.instance.client;
        final annotationsData =
            await loadLocalAnnotations(doc.fileName, targetUserId);
        if (annotationsData != null) {
          final payload = {
            'user_id': targetUserId,
            'document_name': doc.fileName,
            'strokes_data': annotationsData['strokes'] ?? [],
            'texts_data': annotationsData['texts'] ?? [],
            'images_data': annotationsData['images'] ?? [],
            'updated_at': annotationsData['updated_at'] ??
                DateTime.now().toUtc().toIso8601String(),
          };
          client
              .from('document_annotations')
              .upsert(payload, onConflict: 'document_name')
              .then((_) {})
              .catchError((_) {});
        }
      } catch (_) {}

      if (triggerCloudSync) {
        AutoSyncService.instance.triggerSync(immediate: true);
      }
    } catch (_) {}
  }

  /// Removes a document from local storage and Supabase
  static Future<void> deleteDocument(String fileName, [String? userId]) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final docs = await loadSavedDocuments(targetUserId);
      docs.removeWhere((d) => d.fileName == fileName);
      await _persistDocumentsList(docs, targetUserId);
      await clearLocalAnnotations(fileName, targetUserId);

      // Async background deletion from Supabase
      try {
        final client = Supabase.instance.client;
        await client
            .from('document_annotations')
            .delete()
            .eq('document_name', fileName)
            .eq('user_id', targetUserId);
      } catch (_) {}

      AutoSyncService.instance.triggerSync(immediate: true);
    } catch (_) {}
  }

  /// Saves full annotation payload to local SharedPreferences & triggers cloud auto-upload
  static Future<void> saveLocalAnnotations(
    String documentName, {
    required List<Stroke> strokes,
    required List<TextAnnotation> texts,
    required List<ImageAnnotation> images,
    Map<String, dynamic>? extraData,
    bool triggerCloudSync = true,
    String? userId,
  }) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> data = {
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'texts': texts.map((t) => t.toJson()).toList(),
        'images': images.map((i) => i.toJson()).toList(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (extraData != null) {
        data.addAll(extraData);
      }
      await prefs.setString(
          _getScopedAnnotationsKey(documentName, targetUserId), jsonEncode(data));

      // Immediate auto-upload of annotations to Supabase database
      try {
        final client = Supabase.instance.client;
        final payload = {
          'user_id': targetUserId,
          'document_name': documentName,
          'strokes_data': strokes.map((s) => s.toJson()).toList(),
          'texts_data': texts.map((t) => t.toJson()).toList(),
          'images_data': images.map((i) => i.toJson()).toList(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };
        client
            .from('document_annotations')
            .upsert(payload, onConflict: 'document_name')
            .then((_) {})
            .catchError((_) {});
      } catch (_) {}

      if (triggerCloudSync) {
        AutoSyncService.instance.triggerSync(immediate: true);
      }
    } catch (_) {}
  }

  /// Loads full annotation payload from local SharedPreferences
  static Future<Map<String, dynamic>?> loadLocalAnnotations(
      String documentName, [String? userId]) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final prefs = await SharedPreferences.getInstance();
      final scopedKey = _getScopedAnnotationsKey(documentName, targetUserId);
      final String? jsonString = prefs.getString(scopedKey);

      if (jsonString != null && jsonString.isNotEmpty) {
        return jsonDecode(jsonString) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Clears local annotations for a document
  static Future<void> clearLocalAnnotations(
      String documentName, [String? userId]) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_getScopedAnnotationsKey(documentName, targetUserId));
    } catch (_) {}
  }

  /// Saves the complete document list to SharedPreferences
  static Future<void> _persistDocumentsList(
      List<DocumentItem> docs, [String? userId]) async {
    final targetUserId = userId ?? UserService.instance.activeUserId;
    final prefs = await SharedPreferences.getInstance();
    final String encoded =
        jsonEncode(docs.map((d) => d.toJson()).toList());
    await prefs.setString(_getScopedDocumentsKey(targetUserId), encoded);
  }

  // ==========================================
  // HANDWRITING NOTES PERSISTENCE & CLOUD SYNC
  // ==========================================

  /// Loads all saved handwriting notes from SharedPreferences scoped strictly for the active user
  static Future<List<HandwritingNote>> loadHandwritingNotes(
      [String? userId]) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final prefs = await SharedPreferences.getInstance();
      final scopedKey = _getScopedNotesKey(targetUserId);
      final String? jsonString = prefs.getString(scopedKey);

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final List<dynamic> decodedList =
          jsonDecode(jsonString) as List<dynamic>;
      final List<HandwritingNote> notes = decodedList
          .map((item) => HandwritingNote.fromJson(
              Map<String, dynamic>.from(item as Map)))
          .toList();

      // Sort newest first
      notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return notes;
    } catch (_) {
      return [];
    }
  }

  /// Saves or updates a handwriting note in persistent storage and triggers cloud auto-sync
  static Future<void> saveOrUpdateHandwritingNote(
    HandwritingNote note, {
    bool triggerCloudSync = true,
    String? userId,
  }) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final notes = await loadHandwritingNotes(targetUserId);
      final existingIndex = notes.indexWhere((n) => n.id == note.id);

      if (existingIndex >= 0) {
        notes[existingIndex] = note;
      } else {
        notes.insert(0, note);
      }

      // Keep max 100 recent handwriting notes per user
      if (notes.length > 100) {
        notes.removeRange(100, notes.length);
      }

      await _persistHandwritingNotesList(notes, targetUserId);

      // Immediate auto-upload of note to Supabase database in background
      try {
        final client = Supabase.instance.client;
        final payload = {
          'id': note.id,
          'user_id': targetUserId,
          'title': note.title,
          'content': note.content,
          'palette_index': note.paletteIndex,
          'updated_at': note.updatedAt.toUtc().toIso8601String(),
          'created_at': note.createdAt.toUtc().toIso8601String(),
          if (note.strokesJson != null) 'strokes_json': note.strokesJson,
          'is_handwritten': note.isHandwritten,
        };
        client
            .from('handwriting_notes')
            .upsert(payload, onConflict: 'id')
            .then((_) {})
            .catchError((_) {});
      } catch (_) {}

      if (triggerCloudSync) {
        AutoSyncService.instance.triggerSync(immediate: true);
      }
    } catch (_) {}
  }

  /// Deletes a handwriting note from local storage and Supabase
  static Future<void> deleteHandwritingNote(String id, [String? userId]) async {
    try {
      final targetUserId = userId ?? UserService.instance.activeUserId;
      final notes = await loadHandwritingNotes(targetUserId);
      notes.removeWhere((n) => n.id == id);
      await _persistHandwritingNotesList(notes, targetUserId);

      // Async background deletion from Supabase
      try {
        final client = Supabase.instance.client;
        await client
            .from('handwriting_notes')
            .delete()
            .eq('id', id)
            .eq('user_id', targetUserId);
      } catch (_) {}

      AutoSyncService.instance.triggerSync(immediate: true);
    } catch (_) {}
  }

  /// Saves the complete handwriting notes list to SharedPreferences
  static Future<void> _persistHandwritingNotesList(
      List<HandwritingNote> notes, [String? userId]) async {
    final targetUserId = userId ?? UserService.instance.activeUserId;
    final prefs = await SharedPreferences.getInstance();
    final String encoded =
        jsonEncode(notes.map((n) => n.toJson()).toList());
    await prefs.setString(_getScopedNotesKey(targetUserId), encoded);
  }
}
