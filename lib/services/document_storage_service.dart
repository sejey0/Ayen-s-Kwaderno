import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/document_item_model.dart';
import '../models/handwriting_note_model.dart';
import '../models/image_annotation_model.dart';
import '../models/stroke_model.dart';
import '../models/text_annotation_model.dart';

/// Manages persistent local storage of recently opened/imported documents, annotations, and handwriting notes using SharedPreferences and background Supabase sync
class DocumentStorageService {
  static const String _documentsKey = 'ayens_kwaderno_recent_documents_v2';
  static const String _handwritingNotesKey =
      'ayens_kwaderno_handwriting_notes_v1';
  static String _annotationsKey(String documentName) =>
      'ayens_kwaderno_annotations_$documentName';

  // ==========================================
  // DOCUMENT FILES PERSISTENCE
  // ==========================================

  /// Loads all saved documents from SharedPreferences
  static Future<List<DocumentItem>> loadSavedDocuments() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString(_documentsKey);

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

  /// Saves or updates a document in persistent storage
  static Future<void> saveOrUpdateDocument(DocumentItem doc) async {
    try {
      final docs = await loadSavedDocuments();

      // Remove existing entry by filename if any
      final existingIndex = docs.indexWhere((d) => d.fileName == doc.fileName);

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

      // Keep max 50 recent documents
      if (docs.length > 50) {
        docs.removeRange(50, docs.length);
      }

      await _persistDocumentsList(docs);
    } catch (_) {}
  }

  /// Removes a document from local storage
  static Future<void> deleteDocument(String fileName) async {
    try {
      final docs = await loadSavedDocuments();
      docs.removeWhere((d) => d.fileName == fileName);
      await _persistDocumentsList(docs);
      await clearLocalAnnotations(fileName);
    } catch (_) {}
  }

  /// Saves full annotation payload (strokes, texts, images) to local SharedPreferences
  static Future<void> saveLocalAnnotations(
    String documentName, {
    required List<Stroke> strokes,
    required List<TextAnnotation> texts,
    required List<ImageAnnotation> images,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'texts': texts.map((t) => t.toJson()).toList(),
        'images': images.map((i) => i.toJson()).toList(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      await prefs.setString(_annotationsKey(documentName), jsonEncode(data));
    } catch (_) {}
  }

  /// Loads full annotation payload from local SharedPreferences
  static Future<Map<String, dynamic>?> loadLocalAnnotations(
      String documentName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_annotationsKey(documentName));
      if (jsonString != null && jsonString.isNotEmpty) {
        return jsonDecode(jsonString) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Clears local annotations for a document
  static Future<void> clearLocalAnnotations(String documentName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_annotationsKey(documentName));
    } catch (_) {}
  }

  /// Saves the complete document list to SharedPreferences
  static Future<void> _persistDocumentsList(List<DocumentItem> docs) async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(docs.map((d) => d.toJson()).toList());
    await prefs.setString(_documentsKey, encoded);
  }

  // ==========================================
  // HANDWRITING NOTES PERSISTENCE & CLOUD SYNC
  // ==========================================

  /// Loads all saved handwriting notes from SharedPreferences
  static Future<List<HandwritingNote>> loadHandwritingNotes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString(_handwritingNotesKey);

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final List<dynamic> decodedList = jsonDecode(jsonString) as List<dynamic>;
      final List<HandwritingNote> notes = decodedList
          .map((item) =>
              HandwritingNote.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

      // Sort newest first
      notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return notes;
    } catch (_) {
      return [];
    }
  }

  /// Saves or updates a handwriting note in persistent storage and syncs to Supabase
  static Future<void> saveOrUpdateHandwritingNote(HandwritingNote note) async {
    try {
      final notes = await loadHandwritingNotes();
      final existingIndex = notes.indexWhere((n) => n.id == note.id);

      if (existingIndex >= 0) {
        notes[existingIndex] = note;
      } else {
        notes.insert(0, note);
      }

      // Keep max 100 recent handwriting notes
      if (notes.length > 100) {
        notes.removeRange(100, notes.length);
      }

      await _persistHandwritingNotesList(notes);

      // Async background sync to Supabase table `handwriting_notes`
      _syncNoteToCloudBackground(note);
    } catch (_) {}
  }

  /// Background sync to Supabase
  static Future<void> _syncNoteToCloudBackground(HandwritingNote note) async {
    try {
      final client = Supabase.instance.client;
      await client.from('handwriting_notes').upsert({
        'id': note.id,
        'title': note.title,
        'content': note.content,
        'palette_index': note.paletteIndex,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'created_at': note.createdAt.toUtc().toIso8601String(),
      }, onConflict: 'id');
    } catch (e) {
      debugPrint('Cloud note sync notice (unconfigured table or offline): $e');
    }
  }

  /// Deletes a handwriting note from local storage and Supabase
  static Future<void> deleteHandwritingNote(String id) async {
    try {
      final notes = await loadHandwritingNotes();
      notes.removeWhere((n) => n.id == id);
      await _persistHandwritingNotesList(notes);

      // Async background deletion from Supabase
      try {
        final client = Supabase.instance.client;
        await client.from('handwriting_notes').delete().eq('id', id);
      } catch (_) {}
    } catch (_) {}
  }

  /// Saves the complete handwriting notes list to SharedPreferences
  static Future<void> _persistHandwritingNotesList(
      List<HandwritingNote> notes) async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(notes.map((n) => n.toJson()).toList());
    await prefs.setString(_handwritingNotesKey, encoded);
  }
}
