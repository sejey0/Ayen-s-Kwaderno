import 'package:flutter/material.dart';

/// Represents a digital text annotation placed and draggable on top of the document
class TextAnnotation {
  final String id;
  String text;
  Offset position;
  Color color;
  double fontSize;

  TextAnnotation({
    String? id,
    required this.text,
    required this.position,
    this.color = const Color(0xFF2D2640),
    this.fontSize = 16.0,
  }) : id = id ?? UniqueKey().toString();

  TextAnnotation copyWith({
    String? id,
    String? text,
    Offset? position,
    Color? color,
    double? fontSize,
  }) {
    return TextAnnotation(
      id: id ?? this.id,
      text: text ?? this.text,
      position: position ?? this.position,
      color: color ?? this.color,
      fontSize: fontSize ?? this.fontSize,
    );
  }

  /// Converts text annotation to JSON map for Supabase storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'x': position.dx,
      'y': position.dy,
      'color': color.toARGB32(),
      'fontSize': fontSize,
    };
  }

  /// Deserializes a TextAnnotation from Supabase / JSON map
  factory TextAnnotation.fromJson(Map<String, dynamic> json) {
    return TextAnnotation(
      id: json['id'] as String?,
      text: json['text'] as String? ?? '',
      position: Offset(
        (json['x'] as num?)?.toDouble() ?? 100.0,
        (json['y'] as num?)?.toDouble() ?? 100.0,
      ),
      color: Color(json['color'] as int? ?? 0xFF2D2640),
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
    );
  }
}
