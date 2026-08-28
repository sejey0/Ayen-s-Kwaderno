import 'package:flutter/material.dart';

/// Represents a draggable, resizable, customizable image sticker overlay on the document
class ImageAnnotation {
  final String id;
  String imagePath;
  String? originalImagePath;
  Offset position;
  Size size;
  Size? originalSize;
  bool isLocked;
  String shape; // 'rounded', 'rectangle', 'pill', 'circle', 'polaroid'
  String border; // 'white', 'purple', 'none', 'dark'

  ImageAnnotation({
    String? id,
    required this.imagePath,
    String? originalImagePath,
    required this.position,
    this.size = const Size(200.0, 200.0),
    Size? originalSize,
    this.isLocked = false,
    this.shape = 'rounded',
    this.border = 'white',
  })  : id = id ?? UniqueKey().toString(),
        originalImagePath = originalImagePath ?? imagePath,
        originalSize = originalSize ?? size;

  ImageAnnotation copyWith({
    String? id,
    String? imagePath,
    String? originalImagePath,
    Offset? position,
    Size? size,
    Size? originalSize,
    bool? isLocked,
    String? shape,
    String? border,
  }) {
    return ImageAnnotation(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      originalImagePath: originalImagePath ?? this.originalImagePath,
      position: position ?? this.position,
      size: size ?? this.size,
      originalSize: originalSize ?? this.originalSize,
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
      'originalImagePath': originalImagePath,
      'x': position.dx,
      'y': position.dy,
      'width': size.width,
      'height': size.height,
      'originalWidth': originalSize?.width,
      'originalHeight': originalSize?.height,
      'isLocked': isLocked,
      'shape': shape,
      'border': border,
    };
  }

  /// Deserializes ImageAnnotation from Supabase / JSON map
  factory ImageAnnotation.fromJson(Map<String, dynamic> json) {
    final width = (json['width'] as num?)?.toDouble() ?? 200.0;
    final height = (json['height'] as num?)?.toDouble() ?? 200.0;
    final origW = (json['originalWidth'] as num?)?.toDouble() ?? width;
    final origH = (json['originalHeight'] as num?)?.toDouble() ?? height;

    return ImageAnnotation(
      id: json['id'] as String?,
      imagePath: json['imagePath'] as String? ?? '',
      originalImagePath: json['originalImagePath'] as String?,
      position: Offset(
        (json['x'] as num?)?.toDouble() ?? 100.0,
        (json['y'] as num?)?.toDouble() ?? 100.0,
      ),
      size: Size(width, height),
      originalSize: Size(origW, origH),
      isLocked: json['isLocked'] as bool? ?? false,
      shape: json['shape'] as String? ?? 'rounded',
      border: json['border'] as String? ?? 'white',
    );
  }
}
