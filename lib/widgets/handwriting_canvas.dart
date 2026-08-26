import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;
import '../theme/app_theme.dart';

class HandwritingCanvasDialog extends StatefulWidget {
  final String languageCode;

  const HandwritingCanvasDialog({
    super.key,
    this.languageCode = 'en-US',
  });

  /// Static helper to launch the dialog
  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) => const HandwritingCanvasDialog(),
    );
  }

  @override
  State<HandwritingCanvasDialog> createState() =>
      _HandwritingCanvasDialogState();
}

class _HandwritingCanvasDialogState extends State<HandwritingCanvasDialog> {
  final mlkit.DigitalInkRecognizerModelManager _modelManager =
      mlkit.DigitalInkRecognizerModelManager();
  late mlkit.DigitalInkRecognizer _recognizer;

  // ML Kit Digital Ink Data
  final mlkit.Ink _ink = mlkit.Ink();
  mlkit.Stroke? _currentInkStroke;

  // UI Drawing Points for instant local visual rendering
  final List<List<Offset>> _drawnStrokes = [];
  List<Offset> _currentDrawnPoints = [];

  // Model & Recognition State
  bool _isModelReady = false;
  bool _isDownloadingModel = false;
  bool _isRecognizing = false;
  String _statusMessage = 'Ready to write';

  @override
  void initState() {
    super.initState();
    _recognizer =
        mlkit.DigitalInkRecognizer(languageCode: widget.languageCode);
    _initializeModel();
  }

  @override
  void dispose() {
    _recognizer.close();
    super.dispose();
  }

  Future<void> _initializeModel() async {
    try {
      final isDownloaded =
          await _modelManager.isModelDownloaded(widget.languageCode);
      if (!isDownloaded) {
        setState(() {
          _isDownloadingModel = true;
          _statusMessage = 'Downloading language model (${widget.languageCode})...';
        });

        await _modelManager.downloadModel(widget.languageCode);
      }

      if (mounted) {
        setState(() {
          _isModelReady = true;
          _isDownloadingModel = false;
          _statusMessage = 'Model ready • Write on the pad below';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloadingModel = false;
          _isModelReady = true; // Still allow trying or typing fallback
          _statusMessage = 'Model download notice: $e';
        });
      }
    }
  }

  void _onPanStart(DragStartDetails details) {
    _currentInkStroke = mlkit.Stroke();
    final point = mlkit.StrokePoint(
      x: details.localPosition.dx,
      y: details.localPosition.dy,
      t: DateTime.now().millisecondsSinceEpoch,
    );
    _currentInkStroke!.points.add(point);

    setState(() {
      _currentDrawnPoints = [details.localPosition];
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final point = mlkit.StrokePoint(
      x: details.localPosition.dx,
      y: details.localPosition.dy,
      t: DateTime.now().millisecondsSinceEpoch,
    );
    _currentInkStroke?.points.add(point);

    setState(() {
      _currentDrawnPoints.add(details.localPosition);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_currentInkStroke != null) {
      _ink.strokes.add(_currentInkStroke!);
      _currentInkStroke = null;
    }

    if (_currentDrawnPoints.isNotEmpty) {
      setState(() {
        _drawnStrokes.add(List.from(_currentDrawnPoints));
        _currentDrawnPoints.clear();
      });
    }
  }

  void _clearCanvas() {
    setState(() {
      _ink.strokes.clear();
      _currentInkStroke = null;
      _drawnStrokes.clear();
      _currentDrawnPoints.clear();
      _statusMessage = 'Canvas cleared';
    });
  }

  Future<void> _recognizeAndSubmit() async {
    if (_ink.strokes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Please write your note on the paper first.'),
            ],
          ),
          backgroundColor: AppTheme.textPrimary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _isRecognizing = true;
      _statusMessage = 'Recognizing handwriting...';
    });

    try {
      final candidates = await _recognizer.recognize(_ink);

      if (!mounted) return;
      setState(() => _isRecognizing = false);

      if (candidates.isNotEmpty && candidates.first.text.trim().isNotEmpty) {
        final recognizedText = candidates.first.text.trim();
        Navigator.of(context).pop(recognizedText);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Could not recognize text. Please write clearly and try again.',
            ),
            backgroundColor: AppTheme.textPrimary,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRecognizing = false;
        _statusMessage = 'Recognition error: $e';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.accentPinkDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.65 + bottomInset,
      decoration: const BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
      ),
      child: Column(
        children: [
          // Top Sheet Handle & Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              children: [
                // Top drag pill
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Title Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                AppTheme.primaryPurple,
                                AppTheme.accentPink,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            CupertinoIcons.pencil_ellipsis_rectangle,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Handwriting to Text',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                            Text(
                              'Google ML Kit AI Recognition',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Language Badge & Close Button
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryPurpleLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            widget.languageCode,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primaryPurpleDark,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(
                            CupertinoIcons.xmark_circle_fill,
                            color: AppTheme.textMuted,
                            size: 24,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Status / Model downloading indicator bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            color: _isDownloadingModel
                ? AppTheme.accentPinkLight
                : AppTheme.background,
            child: Row(
              children: [
                if (_isDownloadingModel || _isRecognizing) ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.primaryPurple,
                    ),
                  ),
                  const SizedBox(width: 8),
                ] else ...[
                  Icon(
                    CupertinoIcons.checkmark_alt_circle_fill,
                    size: 14,
                    color: _isModelReady
                        ? const Color(0xFF10B981)
                        : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (_drawnStrokes.isNotEmpty || _currentDrawnPoints.isNotEmpty)
                  Text(
                    '${_drawnStrokes.length} stroke${_drawnStrokes.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.primaryPurple,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),

          // Paper Writing Pad Surface (Ruled stationery style)
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFCFBFE),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.primaryPurpleLight,
                  width: 1.5,
                ),
                boxShadow: AppTheme.softShadow,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  children: [
                    // Ruled Line Paper Background
                    const Positioned.fill(
                      child: CustomPaint(
                        painter: RuledPaperPainter(),
                      ),
                    ),

                    // Drawing Gesture Detector & Visual Ink Canvas
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: _onPanStart,
                        onPanUpdate: _onPanUpdate,
                        onPanEnd: _onPanEnd,
                        child: CustomPaint(
                          painter: HandwritingInkPainter(
                            strokes: _drawnStrokes,
                            currentStroke: _currentDrawnPoints,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    ),

                    // Empty State Watermark
                    if (_drawnStrokes.isEmpty && _currentDrawnPoints.isEmpty)
                      const Center(
                        child: IgnorePointer(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.signature,
                                size: 48,
                                color: Color(0xFFE2DCF7),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Write your notes or formulas here ✨',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textMuted,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Action Bar: Clear & Done / Convert Buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Row(
              children: [
                // Clear Button
                Expanded(
                  flex: 1,
                  child: OutlinedButton.icon(
                    onPressed: (_drawnStrokes.isEmpty &&
                            _currentDrawnPoints.isEmpty)
                        ? null
                        : _clearCanvas,
                    icon: const Icon(CupertinoIcons.trash, size: 16),
                    label: const Text('Clear'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                      side: const BorderSide(color: AppTheme.dividerColor),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                // Convert / Done Button
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _isRecognizing ? null : _recognizeAndSubmit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            AppTheme.primaryPurple,
                            AppTheme.accentPink,
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryPurple.withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: _isRecognizing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    CupertinoIcons.sparkles,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Convert to Text',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter that draws subtle notebook ruled guide lines
class RuledPaperPainter extends CustomPainter {
  const RuledPaperPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = const Color(0xFFECE7F6)
      ..strokeWidth = 1.0;

    const spacing = 32.0;
    for (double y = spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(16, y), Offset(size.width - 16, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Custom painter for real-time handwriting ink rendering on the popup canvas
class HandwritingInkPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> currentStroke;

  HandwritingInkPainter({
    required this.strokes,
    required this.currentStroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2D2640)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Draw historical strokes
    for (final stroke in strokes) {
      _drawPath(canvas, stroke, paint);
    }

    // Draw active stroke
    if (currentStroke.isNotEmpty) {
      _drawPath(canvas, currentStroke, paint);
    }
  }

  void _drawPath(Canvas canvas, List<Offset> points, Paint paint) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      canvas.drawCircle(
        points.first,
        paint.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
      paint.style = PaintingStyle.stroke;
      return;
    }

    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);

    for (int i = 1; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    path.lineTo(points.last.dx, points.last.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant HandwritingInkPainter oldDelegate) => true;
}
