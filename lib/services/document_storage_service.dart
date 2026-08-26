import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/document_item_model.dart';
import '../models/image_annotation_model.dart';
import '../models/stroke_model.dart';
import '../models/text_annotation_model.dart';

/// Manages persistent local storage of recently opened/imported documents and their annotations using SharedPreferences
class DocumentStorageService {
  static const String _documentsKey = 'ayens_kwaderno_recent_documents_v2';
  static String _annotationsKey(String documentName) =>
      'ayens_kwaderno_annotations_$documentName';

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

      await _persistList(docs);
    } catch (_) {}
  }

  /// Removes a document from local storage
  static Future<void> deleteDocument(String fileName) async {
    try {
      final docs = await loadSavedDocuments();
      docs.removeWhere((d) => d.fileName == fileName);
      await _persistList(docs);
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

  /// Saves the complete list to SharedPreferences
  static Future<void> _persistList(List<DocumentItem> docs) async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(docs.map((d) => d.toJson()).toList());
    await prefs.setString(_documentsKey, encoded);
  }
}
