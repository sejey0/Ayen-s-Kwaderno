import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/handwriting_canvas.dart';

/// Service that leverages Google Gemini Multimodal Vision AI for ultra-accurate
/// handwriting recognition from canvas strokes, formulas, cursive, and notes.
class GeminiHandwritingService {
  static const String _geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  static const String _prefKeyGeminiApiKey = 'custom_gemini_api_key';

  /// Retrieves the active Gemini API key from .env or SharedPreferences
  static Future<String?> getActiveApiKey() async {
    // 1. Check user custom key from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final customKey = prefs.getString(_prefKeyGeminiApiKey);
    if (customKey != null && customKey.trim().isNotEmpty) {
      return customKey.trim();
    }

    // 2. Check .env file
    final envKey = dotenv.env['GEMINI_API_KEY'];
    if (envKey != null && envKey.trim().isNotEmpty) {
      return envKey.trim();
    }

    return null;
  }

  /// Sets a custom Gemini API key in SharedPreferences
  static Future<void> setCustomApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyGeminiApiKey, key.trim());
  }

  /// Converts vector handwriting strokes into a clean, high-contrast PNG byte array
  static Future<Uint8List?> renderStrokesToPng({
    required List<HandwritingStroke> strokes,
    double width = 800,
    double height = 800,
  }) async {
    if (strokes.isEmpty) return null;

    // Calculate bounding box with padding
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final s in strokes) {
      for (final p in s.points) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
    }

    final strokeW = (maxX - minX).clamp(100.0, 4000.0);
    final strokeH = (maxY - minY).clamp(100.0, 4000.0);
    const double padding = 50.0;

    final targetW = (strokeW + padding * 2).clamp(400.0, 1400.0);
    final targetH = (strokeH + padding * 2).clamp(400.0, 1400.0);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, targetW, targetH),
    );

    // 1. Draw solid white paper background
    final bgPaint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, targetW, targetH), bgPaint);

    // 2. Translate strokes to center
    canvas.save();
    canvas.translate(padding - minX, padding - minY);

    // 3. Draw all strokes
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;

      final paint = Paint()
        ..color = stroke.isHighlighter
            ? stroke.color.withValues(alpha: 0.45)
            : stroke.color
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.strokeWidth
        ..style = PaintingStyle.stroke;

      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, stroke.strokeWidth / 2,
            paint..style = PaintingStyle.fill);
      } else {
        final path = Path();
        path.moveTo(stroke.points.first.dx, stroke.points.first.dy);
        for (int i = 1; i < stroke.points.length; i++) {
          path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
        }
        canvas.drawPath(path, paint);
      }
    }

    canvas.restore();

    final picture = recorder.endRecording();
    final img = await picture.toImage(targetW.toInt(), targetH.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);

    return byteData?.buffer.asUint8List();
  }

  /// Sends the rendered handwriting PNG to Google Gemini Vision AI for transcription
  static Future<String?> transcribeWithGemini(
      List<HandwritingStroke> strokes) async {
    if (strokes.isEmpty) return null;

    final apiKey = await getActiveApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('No Gemini API key found. Using On-Device ML Kit.');
      return null;
    }

    try {
      final pngBytes = await renderStrokesToPng(strokes: strokes);
      if (pngBytes == null) return null;

      final base64Image = base64Encode(pngBytes);
      final url = Uri.parse('$_geminiEndpoint?key=$apiKey');

      final requestBody = jsonEncode({
        "contents": [
          {
            "parts": [
              {
                "text":
                    "You are an expert handwriting-to-text transcriber for student notebooks and study notes. Transcribe all the handwriting, letters, words, sentences, or math in this image exactly as written. If it is a single character like 'A', output just 'A'. Output ONLY the clean transcribed text without conversational preamble, quotes, or markdown code blocks."
              },
              {
                "inline_data": {
                  "mime_type": "image/png",
                  "data": base64Image
                }
              }
            ]
          }
        ],
        "generationConfig": {
          "temperature": 0.1,
          "maxOutputTokens": 1024,
        }
      });

      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: requestBody,
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        final candidates = jsonResponse['candidates'] as List<dynamic>?;
        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates.first['content'] as Map<String, dynamic>?;
          final parts = content?['parts'] as List<dynamic>?;
          if (parts != null && parts.isNotEmpty) {
            final transcribedText =
                (parts.first['text'] as String?)?.trim() ?? '';
            if (transcribedText.isNotEmpty) {
              debugPrint('🧠 Gemini Vision AI Transcribed: "$transcribedText"');
              return transcribedText;
            }
          }
        }
      } else {
        debugPrint(
            'Gemini API error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Gemini handwriting transcription notice: $e');
    }

    return null;
  }
}
