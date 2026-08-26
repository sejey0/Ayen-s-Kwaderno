/// Represents a digital handwriting note recognized via Google ML Kit
class HandwritingNote {
  final String id;
  final String title;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int paletteIndex;
  final bool isCloudSynced;

  HandwritingNote({
    String? id,
    required this.title,
    required this.content,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.paletteIndex = 0,
    this.isCloudSynced = false,
  })  : id = id ?? 'note_${DateTime.now().millisecondsSinceEpoch}',
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  HandwritingNote copyWith({
    String? id,
    String? title,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? paletteIndex,
    bool? isCloudSynced,
  }) {
    return HandwritingNote(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      paletteIndex: paletteIndex ?? this.paletteIndex,
      isCloudSynced: isCloudSynced ?? this.isCloudSynced,
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
    };
  }

  factory HandwritingNote.fromJson(Map<String, dynamic> json) {
    return HandwritingNote(
      id: json['id'] as String? ?? 'note_${DateTime.now().millisecondsSinceEpoch}',
      title: json['title'] as String? ?? 'Quick Note',
      content: json['content'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toLocal() ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toLocal() ?? DateTime.now()
          : DateTime.now(),
      paletteIndex: json['palette_index'] as int? ?? 0,
      isCloudSynced: json['is_cloud_synced'] as bool? ?? false,
    );
  }
}
