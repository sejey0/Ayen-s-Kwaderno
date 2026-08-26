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
  final TextEditingController _typeTextController = TextEditingController();

  // Mode: 0 = Handwriting Pad, 1 = Type Note
  int _currentTab = 0;

  // ML Kit Digital Ink Data
  final mlkit.Ink _ink = mlkit.Ink();
  mlkit.Stroke? _currentInkStroke;

  // UI Drawing Points for instant local visual rendering
  final List<List<Offset>> _drawnStrokes = [];
  List<Offset> _currentDrawnPoints = [];

  // Model & Recognition State
  bool _isDownloadingModel = false;
  bool _isRecognizing = false;
  bool _hasPluginError = false;
  String _statusMessage = 'Write your notes or formulas below ✨';

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
    _typeTextController.dispose();
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
          _isDownloadingModel = false;
          _hasPluginError = false;
          _statusMessage = 'Model ready • Write on the pad below';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloadingModel = false;
          _hasPluginError = true;
          _statusMessage = 'ML Kit native plugin requires a full app restart. You can type or write notes below!';
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
    // If typing tab is active
    if (_currentTab == 1) {
      final typed = _typeTextController.text.trim();
      if (typed.isNotEmpty) {
        Navigator.of(context).pop(typed);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please type some text for your note.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // If drawing tab is active
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
              'Could not recognize text. Please write clearly or switch to Type Note.',
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
        _hasPluginError = true;
        _currentTab = 1; // Seamless fallback to Type mode
        _statusMessage =
            'Native ML Kit needs cold restart. Enter your note below:';
      });

      // Prompt user to type note without losing their momentum
      showCupertinoDialog(
        context: context,
        builder: (dialogCtx) => CupertinoAlertDialog(
          title: const Text('Save Note'),
          content: const Text(
            'ML Kit native binary needs a cold restart (run.bat option [1]). In the meantime, you can type your note to save it directly!',
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              child: const Text('Type & Save'),
              onPressed: () => Navigator.pop(dialogCtx),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.72 + bottomInset,
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

                // Title Row with Tab Switcher
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
                              'Handwriting & Notes',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                            Text(
                              'Digital Ink & Instant Note Creator',
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
                const SizedBox(height: 10),

                // Mode Tabs (Draw / Type)
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: AppTheme.background,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _currentTab = 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            decoration: BoxDecoration(
                              color: _currentTab == 0
                                  ? Colors.white
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: _currentTab == 0
                                  ? [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.04),
                                        blurRadius: 4,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  CupertinoIcons.pencil,
                                  size: 14,
                                  color: _currentTab == 0
                                      ? AppTheme.primaryPurple
                                      : AppTheme.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Handwriting Pad',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: _currentTab == 0
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: _currentTab == 0
                                        ? AppTheme.primaryPurple
                                        : AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _currentTab = 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            decoration: BoxDecoration(
                              color: _currentTab == 1
                                  ? Colors.white
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: _currentTab == 1
                                  ? [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.04),
                                        blurRadius: 4,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  CupertinoIcons.keyboard,
                                  size: 14,
                                  color: _currentTab == 1
                                      ? AppTheme.primaryPurple
                                      : AppTheme.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Type Note',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: _currentTab == 1
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: _currentTab == 1
                                        ? AppTheme.primaryPurple
                                        : AppTheme.textSecondary,
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
              ],
            ),
          ),

          // Status / Model downloading indicator bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
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
                ] else if (_hasPluginError) ...[
                  const Icon(
                    CupertinoIcons.info_circle_fill,
                    size: 13,
                    color: Color(0xFFD97706),
                  ),
                  const SizedBox(width: 6),
                ] else ...[
                  const Icon(
                    CupertinoIcons.checkmark_alt_circle_fill,
                    size: 13,
                    color: Color(0xFF10B981),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    _statusMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _hasPluginError
                          ? const Color(0xFFB45309)
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Main Canvas or Typing Area
          Expanded(
            child: _currentTab == 0
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppTheme.primaryPurpleLight,
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryPurple.withValues(alpha: 0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          children: [
                            // Lined Paper Background
                            CustomPaint(
                              painter: LinedPaperPainter(),
                              size: Size.infinite,
                            ),

                            // Watermark Guide
                            if (_drawnStrokes.isEmpty &&
                                _currentDrawnPoints.isEmpty)
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      CupertinoIcons.pencil_outline,
                                      size: 34,
                                      color: AppTheme.primaryPurple
                                          .withValues(alpha: 0.25),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Write your notes or formulas here ✨',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textMuted
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            // Touch Drawing Layer
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: _onPanStart,
                              onPanUpdate: _onPanUpdate,
                              onPanEnd: _onPanEnd,
                              child: CustomPaint(
                                painter: HandwritingDrawingPainter(
                                  strokes: _drawnStrokes,
                                  currentStroke: _currentDrawnPoints,
                                ),
                                size: Size.infinite,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppTheme.primaryPurpleLight,
                          width: 1.5,
                        ),
                      ),
                      child: TextField(
                        controller: _typeTextController,
                        maxLines: null,
                        expands: true,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText:
                              'Type or paste your study notes, formulas, or review pointers...',
                          hintStyle: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 13.5,
                          ),
                          border: InputBorder.none,
                        ),
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textPrimary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
          ),

          // Bottom Action Bar (Clear & Convert / Save)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Row(
              children: [
                // Clear Button
                if (_currentTab == 0)
                  Expanded(
                    flex: 4,
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _drawnStrokes.isNotEmpty ? _clearCanvas : null,
                        icon: const Icon(CupertinoIcons.trash, size: 16),
                        label: const Text('Clear'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.textSecondary,
                          side: BorderSide(
                            color: AppTheme.dividerColor.withValues(alpha: 0.8),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),

                if (_currentTab == 0) const SizedBox(width: 12),

                // Submit Action Button
                Expanded(
                  flex: _currentTab == 0 ? 7 : 12,
                  child: SizedBox(
                    height: 48,
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
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  AppTheme.primaryPurple.withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Container(
                          alignment: Alignment.center,
                          child: _isRecognizing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      _currentTab == 0
                                          ? CupertinoIcons.sparkles
                                          : CupertinoIcons.checkmark_alt,
                                      size: 17,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _currentTab == 0
                                          ? 'Convert to Text'
                                          : 'Save Note',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
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

/// Painter that renders subtle study notebook lines
class LinedPaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE2E8F0).withValues(alpha: 0.7)
      ..strokeWidth = 1.0;

    const double lineSpacing = 32.0;
    for (double y = lineSpacing; y < size.height; y += lineSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Painter for rendering active ink strokes with ink pen effect
class HandwritingDrawingPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> currentStroke;

  HandwritingDrawingPainter({
    required this.strokes,
    required this.currentStroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1E1B4B)
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Draw completed strokes
    for (final stroke in strokes) {
      _drawSmoothStroke(canvas, stroke, paint);
    }

    // Draw current active stroke
    if (currentStroke.isNotEmpty) {
      _drawSmoothStroke(canvas, currentStroke, paint);
    }
  }

  void _drawSmoothStroke(Canvas canvas, List<Offset> points, Paint paint) {
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
  bool shouldRepaint(covariant HandwritingDrawingPainter oldDelegate) => true;
}
