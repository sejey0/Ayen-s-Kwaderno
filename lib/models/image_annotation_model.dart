import 'package:flutter/material.dart';

/// Represents a draggable, resizable, customizable image sticker overlay on the document
class ImageAnnotation {
  final String id;
  String imagePath;
  Offset position;
  Size size;
  bool isLocked;
  String shape; // 'rounded', 'rectangle', 'pill', 'circle', 'polaroid'
  String border; // 'white', 'purple', 'none', 'dark'

  ImageAnnotation({
    String? id,
    required this.imagePath,
    required this.position,
    this.size = const Size(200.0, 200.0),
    this.isLocked = false,
    this.shape = 'rounded',
    this.border = 'white',
  }) : id = id ?? UniqueKey().toString();

  ImageAnnotation copyWith({
    String? id,
    String? imagePath,
    Offset? position,
    Size? size,
    bool? isLocked,
    String? shape,
    String? border,
  }) {
    return ImageAnnotation(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      position: position ?? this.position,
      size: size ?? this.size,
      isLocked: isLocked ?? this.isLocked,
      shape: shape ?? this.shape,
      border: border ?? this.border,
    );
  }

  /// Converts image annotation metadata to JSON map for Supabase sync & persistence
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'imagePath': imagePath,
      'x': position.dx,
      'y': position.dy,
      'width': size.width,
      'height': size.height,
      'isLocked': isLocked,
      'shape': shape,
      'border': border,
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
      isLocked: json['isLocked'] as bool? ?? false,
      shape: json['shape'] as String? ?? 'rounded',
      border: json['border'] as String? ?? 'white',
    );
  }
}
