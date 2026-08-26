/// Represents a persistent document entry stored locally and/or synced with Supabase
class DocumentItem {
  final String fileName;
  String? filePath;
  DateTime lastOpenedAt;
  int annotationsCount;
  bool isCloudSynced;
  int paletteIndex;

  DocumentItem({
    required this.fileName,
    this.filePath,
    required this.lastOpenedAt,
    this.annotationsCount = 0,
    this.isCloudSynced = false,
    this.paletteIndex = 0,
  });

  /// Converts DocumentItem to JSON map for SharedPreferences
  Map<String, dynamic> toJson() {
    return {
      'fileName': fileName,
      'filePath': filePath,
      'lastOpenedAt': lastOpenedAt.toIso8601String(),
      'annotationsCount': annotationsCount,
      'isCloudSynced': isCloudSynced,
      'paletteIndex': paletteIndex,
    };
  }

  /// Deserializes DocumentItem from JSON map
  factory DocumentItem.fromJson(Map<String, dynamic> json) {
    return DocumentItem(
      fileName: json['fileName'] as String? ?? 'Untitled Document',
      filePath: json['filePath'] as String?,
      lastOpenedAt: json['lastOpenedAt'] != null
          ? DateTime.tryParse(json['lastOpenedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      annotationsCount: (json['annotationsCount'] as num?)?.toInt() ?? 0,
      isCloudSynced: json['isCloudSynced'] as bool? ?? false,
      paletteIndex: (json['paletteIndex'] as num?)?.toInt() ?? 0,
    );
  }

  /// Human-friendly relative date string
  String get formattedRelativeDate {
    final difference = DateTime.now().difference(lastOpenedAt);
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${lastOpenedAt.month}/${lastOpenedAt.day}/${lastOpenedAt.year}';
    }
  }

  DocumentItem copyWith({
    String? fileName,
    String? filePath,
    DateTime? lastOpenedAt,
    int? annotationsCount,
    bool? isCloudSynced,
    int? paletteIndex,
  }) {
    return DocumentItem(
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      annotationsCount: annotationsCount ?? this.annotationsCount,
      isCloudSynced: isCloudSynced ?? this.isCloudSynced,
      paletteIndex: paletteIndex ?? this.paletteIndex,
    );
  }
}
