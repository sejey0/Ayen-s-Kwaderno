/// Represents a digital handwriting or typed note
class HandwritingNote {
  final String id;
  final String title;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int paletteIndex;
  final bool isCloudSynced;
  final bool? _isHandwritten;
  final List<Map<String, dynamic>>? strokesJson;

  bool get isHandwritten =>
      _isHandwritten == true ||
      (strokesJson != null && strokesJson!.isNotEmpty) ||
      content.startsWith('Handwritten drawing');

  HandwritingNote({
    String? id,
    required this.title,
    required this.content,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.paletteIndex = 0,
    this.isCloudSynced = false,
    bool isHandwritten = false,
    this.strokesJson,
  })  : id = id ?? 'note_${DateTime.now().millisecondsSinceEpoch}',
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        _isHandwritten = isHandwritten;

  HandwritingNote copyWith({
    String? id,
    String? title,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? paletteIndex,
    bool? isCloudSynced,
    bool? isHandwritten,
    List<Map<String, dynamic>>? strokesJson,
  }) {
    return HandwritingNote(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      paletteIndex: paletteIndex ?? this.paletteIndex,
      isCloudSynced: isCloudSynced ?? this.isCloudSynced,
      isHandwritten: isHandwritten ?? this.isHandwritten,
      strokesJson: strokesJson ?? this.strokesJson,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'palette_index': paletteIndex,
      'is_cloud_synced': isCloudSynced,
      'is_handwritten': isHandwritten,
      'strokes_json': strokesJson,
    };
  }

  factory HandwritingNote.fromJson(Map<String, dynamic> json) {
    final rawStrokes = json['strokes_json'] as List<dynamic>?;
    final parsedStrokes = rawStrokes
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final explicitHandwritten = json['is_handwritten'] as bool?;

    return HandwritingNote(
      id: json['id'] as String? ??
          'note_${DateTime.now().millisecondsSinceEpoch}',
      title: json['title'] as String? ?? 'Quick Note',
      content: json['content'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toLocal() ??
              DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toLocal() ??
              DateTime.now()
          : DateTime.now(),
      paletteIndex: json['palette_index'] as int? ?? 0,
      isCloudSynced: json['is_cloud_synced'] as bool? ?? false,
      isHandwritten: explicitHandwritten == true ||
          (parsedStrokes != null && parsedStrokes.isNotEmpty),
      strokesJson: parsedStrokes,
    );
  }
}
