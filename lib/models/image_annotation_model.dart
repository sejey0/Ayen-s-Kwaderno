import 'package:flutter/material.dart';

/// Represents a draggable, resizable image/photo sticker overlay on top of the document
class ImageAnnotation {
  final String id;
  String imagePath;
  Offset position;
  Size size;

  ImageAnnotation({
    String? id,
    required this.imagePath,
    required this.position,
    this.size = const Size(200.0, 200.0),
  }) : id = id ?? UniqueKey().toString();

  ImageAnnotation copyWith({
    String? id,
    String? imagePath,
    Offset? position,
    Size? size,
  }) {
    return ImageAnnotation(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      position: position ?? this.position,
      size: size ?? this.size,
    );
  }

  /// Converts image annotation metadata to JSON map for Supabase sync
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'imagePath': imagePath,
      'x': position.dx,
      'y': position.dy,
      'width': size.width,
      'height': size.height,
    };
  }

  /// Deserializes ImageAnnotation from Supabase / JSON map
  factory ImageAnnotation.fromJson(Map<String, dynamic> json) {
    return ImageAnnotation(
      id: json['id'] as String?,
      imagePath: json['imagePath'] as String? ?? '',
      position: Offset(
        (json['x'] as num?)?.toDouble() ?? 100.0,
        (json['y'] as num?)?.toDouble() ?? 100.0,
      ),
      size: Size(
        (json['width'] as num?)?.toDouble() ?? 200.0,
        (json['height'] as num?)?.toDouble() ?? 200.0,
      ),
    );
  }
}
