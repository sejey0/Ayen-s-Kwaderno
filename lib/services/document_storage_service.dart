import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/document_item_model.dart';

/// Manages persistent local storage of recently opened/imported documents using SharedPreferences
class DocumentStorageService {
  static const String _documentsKey = 'ayens_kwaderno_recent_documents_v2';

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
          .map((item) => DocumentItem.fromJson(Map<String, dynamic>.from(item as Map)))
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
    } catch (_) {}
  }

  /// Saves the complete list to SharedPreferences
  static Future<void> _persistList(List<DocumentItem> docs) async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(docs.map((d) => d.toJson()).toList());
    await prefs.setString(_documentsKey, encoded);
  }
}
