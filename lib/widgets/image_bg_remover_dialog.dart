import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../services/gemini_handwriting_service.dart';
import '../theme/app_theme.dart';

/// Pure Google Gemini AI-Powered Background Remover Studio Dialog
class ImageBackgroundRemoverDialog extends StatefulWidget {
  final String imagePath;

  const ImageBackgroundRemoverDialog({
    super.key,
    required this.imagePath,
  });

  /// Static helper to open the AI Background Remover dialog
  static Future<String?> show(BuildContext context, String imagePath) {
    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'AI Background Remover',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) =>
          ImageBackgroundRemoverDialog(imagePath: imagePath),
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<ImageBackgroundRemoverDialog> createState() =>
      _ImageBackgroundRemoverDialogState();
}

class _ImageBackgroundRemoverDialogState
    extends State<ImageBackgroundRemoverDialog>
    with SingleTickerProviderStateMixin {
  Uint8List? _originalBytes;
  ui.Image? _processedUiImage;
  bool _isLoading = true;
  bool _isProcessing = false;
  bool _showOriginal = false;
  String? _aiSubjectSummary;
  String _aiStatusMessage = 'Loading image...';

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _loadImageAndRunAi();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadImageAndRunAi() async {
    try {
      final file = File(widget.imagePath);
      final bytes = await file.readAsBytes();

      _originalBytes = bytes;

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _aiStatusMessage = 'Gemini Vision AI is analyzing and isolating subject...';
      });

      // Automatically run AI Background Removal
      await _runGeminiAiRemoval();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load image: $e')),
      );
      Navigator.of(context).pop();
    }
  }

  /// Runs Google Gemini Multimodal Vision AI to cleanly isolate the foreground subject
  Future<void> _runGeminiAiRemoval() async {
    if (_originalBytes == null) return;

    setState(() {
      _isProcessing = true;
      _aiStatusMessage = 'Gemini Vision AI is analyzing and isolating subject...';
    });

    try {
      // 1. Send image to Gemini Vision AI for analysis
      final aiResult =
          await GeminiHandwritingService.analyzeImageForBackgroundRemoval(
              _originalBytes!);

      Color targetColor = Colors.white;
      double tolerance = 0.18;
      double smoothness = 0.08;
      String mode = 'edgeFloodFill';

      if (aiResult != null) {
        final hex = aiResult['dominantBackgroundColorHex'] as String?;
        if (hex != null && hex.isNotEmpty) {
          final cleanHex = hex.replaceAll('#', '').trim();
          if (cleanHex.length == 6) {
            targetColor = Color(int.parse('FF$cleanHex', radix: 16));
          }
        }

        final modeStr = aiResult['mode'] as String?;
        if (modeStr != null && modeStr.isNotEmpty) {
          mode = modeStr;
        }

        final sens = (aiResult['recommendedSensitivity'] as num?)?.toDouble();
        if (sens != null) tolerance = sens.clamp(0.04, 0.60);

        final smooth =
            (aiResult['recommendedSmoothness'] as num?)?.toDouble();
        if (smooth != null) smoothness = smooth.clamp(0.02, 0.25);

        _aiSubjectSummary = aiResult['subjectSummary'] as String?;
      } else {
        // Fallback to sampling corners
        final codec = await ui.instantiateImageCodec(_originalBytes!);
        final frame = await codec.getNextFrame();
        final img = frame.image;
        final byteData =
            await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (byteData != null) {
          targetColor = _sampleCornerColor(
              byteData.buffer.asUint8List(), img.width, img.height);
        }
      }

      // 2. Process High-Performance Pixel Segmentation with AI parameters
      await _executePixelRemoval(
        targetColor: targetColor,
        tolerance: tolerance,
        smoothness: smoothness,
        mode: mode,
      );

      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('Gemini BG error: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Color _sampleCornerColor(Uint8List raw, int w, int h) {
    if (raw.length < 4) return Colors.white;
    final offsets = [
      0,
      (w - 1) * 4,
      (h - 1) * w * 4,
      ((h - 1) * w + (w - 1)) * 4,
    ];
    int rSum = 0, gSum = 0, bSum = 0, count = 0;
    for (final off in offsets) {
      if (off + 3 < raw.length) {
        rSum += raw[off];
        gSum += raw[off + 1];
        bSum += raw[off + 2];
        count++;
      }
    }
    if (count == 0) return Colors.white;
    return Color.fromARGB(255, rSum ~/ count, gSum ~/ count, bSum ~/ count);
  }

  Future<void> _executePixelRemoval({
    required Color targetColor,
    required double tolerance,
    required double smoothness,
    required String mode,
  }) async {
    final codec = await ui.instantiateImageCodec(_originalBytes!);
    final frame = await codec.getNextFrame();
    final srcImage = frame.image;
    final byteData =
        await srcImage.toByteData(format: ui.ImageByteFormat.rawRgba);

    if (byteData == null) {
      setState(() => _isProcessing = false);
      return;
    }

    final w = srcImage.width;
    final h = srcImage.height;
    final raw = Uint8List.fromList(byteData.buffer.asUint8List());

    final targetR = targetColor.r * 255.0;
    final targetG = targetColor.g * 255.0;
    final targetB = targetColor.b * 255.0;

    final double maxDist = 441.67295593;
    final tolDist = tolerance * maxDist;
    final smoothDist = max(0.01, smoothness * maxDist);

    if (mode == 'whitePaperClean') {
      // Scanned Document / White Paper Cleaner
      for (int i = 0; i < raw.length; i += 4) {
        final r = raw[i];
        final g = raw[i + 1];
        final b = raw[i + 2];
        final lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
        final threshold = 1.0 - tolerance * 0.6;
        if (lum >= threshold) {
          final fade = ((1.0 - lum) / (1.0 - threshold)).clamp(0.0, 1.0);
          raw[i + 3] = (raw[i + 3] * fade * fade).clamp(0, 255).toInt();
        }
      }
    } else if (mode == 'globalColor') {
      // Global Chroma Key
      for (int i = 0; i < raw.length; i += 4) {
        final r = raw[i];
        final g = raw[i + 1];
        final b = raw[i + 2];
        final dr = r - targetR;
        final dg = g - targetG;
        final db = b - targetB;
        final dist = sqrt(dr * dr + dg * dg + db * db);

        if (dist <= tolDist) {
          raw[i + 3] = 0;
        } else if (dist <= tolDist + smoothDist) {
          final alphaFactor = (dist - tolDist) / smoothDist;
          raw[i + 3] = (raw[i + 3] * alphaFactor).clamp(0, 255).toInt();
        }
      }
    } else {
      // Edge-Inward Flood Fill: preserves internal colors
      final visited = Uint8List(w * h);
      final queue = Queue<int>();

      for (int x = 0; x < w; x++) {
        queue.add(x);
        queue.add((h - 1) * w + x);
      }
      for (int y = 1; y < h - 1; y++) {
        queue.add(y * w);
        queue.add(y * w + (w - 1));
      }

      while (queue.isNotEmpty) {
        final idx = queue.removeFirst();
        if (idx < 0 || idx >= w * h) continue;
        if (visited[idx] == 1) continue;

        final byteIdx = idx * 4;
        final r = raw[byteIdx];
        final g = raw[byteIdx + 1];
        final b = raw[byteIdx + 2];

        final dr = r - targetR;
        final dg = g - targetG;
        final db = b - targetB;
        final dist = sqrt(dr * dr + dg * dg + db * db);

        if (dist <= tolDist + smoothDist) {
          visited[idx] = 1;

          if (dist <= tolDist) {
            raw[byteIdx + 3] = 0;
          } else {
            final alphaFactor = (dist - tolDist) / smoothDist;
            raw[byteIdx + 3] =
                (raw[byteIdx + 3] * alphaFactor).clamp(0, 255).toInt();
          }

          final px = idx % w;
          final py = idx ~/ w;

          if (px > 0 && visited[idx - 1] == 0) queue.add(idx - 1);
          if (px < w - 1 && visited[idx + 1] == 0) queue.add(idx + 1);
          if (py > 0 && visited[idx - w] == 0) queue.add(idx - w);
          if (py < h - 1 && visited[idx + w] == 0) queue.add(idx + w);
        }
      }
    }

    final descriptor = ui.ImageDescriptor.raw(
      await ui.ImmutableBuffer.fromUint8List(raw),
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codecOut = await descriptor.instantiateCodec();
    final frameOut = await codecOut.getNextFrame();

    if (!mounted) return;
    setState(() {
      _processedUiImage = frameOut.image;
      _isProcessing = false;
    });
  }

  Future<void> _applyAndSave() async {
    if (_processedUiImage == null) return;

    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    try {
      final byteData = await _processedUiImage!.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData == null) throw Exception('Failed to encode PNG');

      final appDir = await getApplicationDocumentsDirectory();
      final targetFile = File(
          '${appDir.path}/aiclean_${DateTime.now().millisecondsSinceEpoch}.png');
      await targetFile.writeAsBytes(byteData.buffer.asUint8List());

      if (!mounted) return;
      Navigator.of(context).pop(targetFile.path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save transparent image: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            // 1. Header Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Cancel / Back Button
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(CupertinoIcons.xmark, size: 16),
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(),
                  ),

                  const SizedBox(width: 8),

                  // Title Badge (Responsive & Fitted)
                  Expanded(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF6366F1),
                              Color(0xFF8B5CF6),
                              Color(0xFFEC4899),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF8B5CF6)
                                  .withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.sparkles,
                              size: 13,
                              color: Colors.white,
                            ),
                            SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                'AI BG Remover',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Apply Button
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 4,
                    ),
                    onPressed: (_isProcessing || _processedUiImage == null)
                        ? null
                        : _applyAndSave,
                    child: _isProcessing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.checkmark_alt, size: 15),
                              SizedBox(width: 4),
                              Text(
                                'Apply',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),

            // 2. Live Canvas Preview
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppTheme.primaryPurple,
                      ),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        // Checkerboard Transparency Background
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _CheckerboardPainter(),
                          ),
                        ),

                        // Image Preview
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: _showOriginal
                                ? Image.file(
                                    File(widget.imagePath),
                                    fit: BoxFit.contain,
                                  )
                                : (_processedUiImage != null
                                    ? RawImage(
                                        image: _processedUiImage,
                                        fit: BoxFit.contain,
                                      )
                                    : Image.file(
                                        File(widget.imagePath),
                                        fit: BoxFit.contain,
                                      )),
                          ),
                        ),

                        // AI Processing Overlay Animation
                        if (_isProcessing)
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.65),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedBuilder(
                                      animation: _pulseController,
                                      builder: (context, child) {
                                        return Container(
                                          padding: const EdgeInsets.all(18),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: const RadialGradient(
                                              colors: [
                                                Color(0xFF8B5CF6),
                                                Color(0xFF6366F1),
                                              ],
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF8B5CF6)
                                                    .withValues(
                                                        alpha: 0.4 +
                                                            _pulseController
                                                                    .value *
                                                                0.4),
                                                blurRadius: 24 +
                                                    _pulseController.value * 12,
                                                spreadRadius: 4,
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            CupertinoIcons.sparkles,
                                            size: 32,
                                            color: Colors.white,
                                          ),
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 18),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 32),
                                      child: Text(
                                        _aiStatusMessage,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                        // AI Subject Pill Badge
                        if (_aiSubjectSummary != null &&
                            !_showOriginal &&
                            !_isProcessing)
                          Positioned(
                            top: 14,
                            left: 14,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF6366F1),
                                    Color(0xFF8B5CF6),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF8B5CF6)
                                        .withValues(alpha: 0.35),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    CupertinoIcons.sparkles,
                                    size: 13,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    'AI Isolated: $_aiSubjectSummary',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        // Before/After Floating Toggle Button
                        if (!_isProcessing)
                          Positioned(
                            top: 14,
                            right: 14,
                            child: GestureDetector(
                              onTapDown: (_) =>
                                  setState(() => _showOriginal = true),
                              onTapUp: (_) =>
                                  setState(() => _showOriginal = false),
                              onTapCancel: () =>
                                  setState(() => _showOriginal = false),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 11, vertical: 7),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _showOriginal
                                          ? CupertinoIcons.eye_fill
                                          : CupertinoIcons.eye,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      _showOriginal
                                          ? 'Original'
                                          : 'Hold to View Original',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),

            // 3. Bottom Action Bar (Re-Analyze & Apply)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Re-Analyze Button
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: const Icon(CupertinoIcons.arrow_counterclockwise,
                        size: 15),
                    label: const Text(
                      'Re-Analyze',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: _isProcessing ? null : _runGeminiAiRemoval,
                  ),

                  const SizedBox(width: 12),

                  // Apply AI Cutout Button
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        backgroundColor: AppTheme.primaryPurple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                      ),
                      onPressed: (_isProcessing || _processedUiImage == null)
                          ? null
                          : _applyAndSave,
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(CupertinoIcons.sparkles,
                              size: 16, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            'Apply AI Cutout',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom Painter drawing a classic transparency checkerboard pattern
class _CheckerboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double squareSize = 14.0;
    final paintLight = Paint()..color = const Color(0xFF1E293B);
    final paintDark = Paint()..color = const Color(0xFF0F172A);

    for (double y = 0; y < size.height; y += squareSize) {
      for (double x = 0; x < size.width; x += squareSize) {
        final isEven =
            ((x / squareSize).floor() + (y / squareSize).floor()) % 2 == 0;
        canvas.drawRect(
          Rect.fromLTWH(x, y, squareSize, squareSize),
          isEven ? paintLight : paintDark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
