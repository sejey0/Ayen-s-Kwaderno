import 'package:flutter/material.dart';

/// Represents a single drawing stroke or straight line annotation
class Stroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final bool isStraightLine;

  Stroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.isStraightLine = false,
  });

  /// Factory helper to copy or clone a stroke
  Stroke copyWith({
    List<Offset>? points,
    Color? color,
    double? strokeWidth,
    bool? isStraightLine,
  }) {
    return Stroke(
      points: points ?? List<Offset>.from(this.points),
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      isStraightLine: isStraightLine ?? this.isStraightLine,
    );
  }

  /// Converts stroke coordinates to JSON-compatible map for Supabase sync
  Map<String, dynamic> toJson() {
    return {
      'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      'color': color.toARGB32(),
      'strokeWidth': strokeWidth,
      'isStraightLine': isStraightLine,
    };
  }

  /// Deserializes a Stroke from Supabase / JSON map
  factory Stroke.fromJson(Map<String, dynamic> json) {
    final pointsList = (json['points'] as List<dynamic>?)
            ?.map((p) => Offset(
                  (p['x'] as num).toDouble(),
                  (p['y'] as num).toDouble(),
                ))
            .toList() ??
        [];

    return Stroke(
      points: pointsList,
      color: Color(json['color'] as int? ?? 0x66FFEB3B),
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 14.0,
      isStraightLine: json['isStraightLine'] as bool? ?? false,
    );
  }
}
