import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;
import '../models/handwriting_note_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';

class HandwritingStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final bool isHighlighter;

  HandwritingStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.isHighlighter = false,
  });
}

/// Full screen pure white canvas studio for handwritten notes
class HandwritingCanvasDialog extends StatefulWidget {
  final String languageCode;

  const HandwritingCanvasDialog({
    super.key,
    this.languageCode = 'en-US',
  });

  /// Static helper to launch the dialog and return the created/saved HandwritingNote
  static Future<HandwritingNote?> show(BuildContext context) {
    return showModalBottomSheet<HandwritingNote>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
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

  final TextEditingController _titleController = TextEditingController();

  // Full Screen / Resize state
  bool _isFullscreen = true; // Default full size white space
  bool _showTools = true; // Toggle for tools overlay

  // Drawing Tools
  bool _isEraser = false;
  Color _selectedColor = const Color(0xFF1E293B); // Charcoal Black
  double _selectedStrokeWidth = 3.5;

  // 7 Ink Colors
  static const List<Color> _inkColors = [
    Color(0xFF1E293B), // Charcoal Black
    Color(0xFF7C3AED), // Royal Purple
    Color(0xFFEC4899), // Pink Rose
    Color(0xFF2563EB), // Ocean Blue
    Color(0xFF059669), // Emerald Green
    Color(0xFFD97706), // Amber Orange
    Color(0xFFFACC15), // Highlighter Yellow
  ];

  // Pen stroke widths
  static const List<double> _strokeWidths = [2.0, 3.5, 6.0, 12.0];

  // ML Kit Digital Ink Data
  final mlkit.Ink _ink = mlkit.Ink();
  mlkit.Stroke? _currentInkStroke;

  // Drawing Strokes
  final List<HandwritingStroke> _strokes = [];
  final List<HandwritingStroke> _undoHistory = [];
  List<Offset> _currentPoints = [];

  // State
  bool _isRecognizing = false;
  bool _hasPluginError = false;

  @override
  void initState() {
    super.initState();
    _recognizer =
        mlkit.DigitalInkRecognizer(languageCode: widget.languageCode);
    _initializeModel();
  }

  @override
  void dispose() {
    try {
      _recognizer.close();
    } catch (_) {}
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _initializeModel() async {
    try {
      final isDownloaded =
          await _modelManager.isModelDownloaded(widget.languageCode);
      if (!isDownloaded) {
        await _modelManager.downloadModel(widget.languageCode);
      }
    } catch (_) {
      if (mounted) setState(() => _hasPluginError = true);
    }
  }

  void _onPanStart(DragStartDetails details) {
    final localPosition = details.localPosition;
    if (_isEraser) {
      _eraseAtPoint(localPosition);
      return;
    }

    setState(() {
      _currentPoints = [localPosition];
      _currentInkStroke = mlkit.Stroke();
      _currentInkStroke!.points.add(
        mlkit.StrokePoint(
          x: localPosition.dx,
          y: localPosition.dy,
          t: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final localPosition = details.localPosition;
    if (_isEraser) {
      _eraseAtPoint(localPosition);
      return;
    }

    setState(() {
      _currentPoints.add(localPosition);
      _currentInkStroke?.points.add(
        mlkit.StrokePoint(
          x: localPosition.dx,
          y: localPosition.dy,
          t: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isEraser) return;

    if (_currentPoints.isNotEmpty) {
      setState(() {
        _strokes.add(
          HandwritingStroke(
            points: List.from(_currentPoints),
            color: _selectedColor,
            strokeWidth: _selectedStrokeWidth,
            isHighlighter: _selectedColor == const Color(0xFFFACC15),
          ),
        );
        _undoHistory.clear();
        _currentPoints = [];

        if (_currentInkStroke != null) {
          _ink.strokes.add(_currentInkStroke!);
          _currentInkStroke = null;
        }
      });
    }
  }

  void _eraseAtPoint(Offset point) {
    const double threshold = 28.0;
    bool erasedAny = false;

    setState(() {
      _strokes.removeWhere((stroke) {
        for (final p in stroke.points) {
          if ((p - point).distance <= threshold) {
            erasedAny = true;
            return true;
          }
        }
        return false;
      });
    });

    if (erasedAny && _ink.strokes.isNotEmpty) {
      _ink.strokes.clear();
    }
  }

  void _undo() {
    if (_strokes.isNotEmpty) {
      setState(() {
        _undoHistory.add(_strokes.removeLast());
        if (_ink.strokes.isNotEmpty) {
          _ink.strokes.removeLast();
        }
      });
    }
  }

  void _redo() {
    if (_undoHistory.isNotEmpty) {
      setState(() {
        _strokes.add(_undoHistory.removeLast());
      });
    }
  }

  void _clearCanvas() {
    setState(() {
      _strokes.clear();
      _undoHistory.clear();
      _currentPoints.clear();
      _ink.strokes.clear();
    });
  }

  Future<String> _recognizeHandwriting() async {
    if (_strokes.isEmpty || _hasPluginError) {
      return '';
    }

    try {
      setState(() => _isRecognizing = true);
      final candidates = await _recognizer.recognize(_ink);
      setState(() => _isRecognizing = false);

      if (candidates.isNotEmpty) {
        return candidates.first.text;
      }
    } catch (_) {
      if (mounted) setState(() => _isRecognizing = false);
    }
    return '';
  }

  Future<void> _saveHandwrittenNote() async {
    final title = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : 'Note ${DateTime.now().month}/${DateTime.now().day}';

    final recognized = await _recognizeHandwriting();
    final content = recognized.isNotEmpty
        ? recognized
        : 'Handwritten drawing (${_strokes.length} strokes)';

    final newNote = HandwritingNote(
      id: 'note_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      content: content,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      paletteIndex: DateTime.now().millisecond % 5,
      isCloudSynced: false,
    );

    await DocumentStorageService.saveOrUpdateHandwritingNote(newNote);

    if (!mounted) return;
    Navigator.of(context).pop(newNote);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "$title" to Written Notes! ✍️'),
        backgroundColor: AppTheme.textPrimary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final safeTop = mediaQuery.viewPadding.top > 0
        ? mediaQuery.viewPadding.top
        : mediaQuery.padding.top;
    final safeBottom = mediaQuery.viewPadding.bottom > 0
        ? mediaQuery.viewPadding.bottom
        : mediaQuery.padding.bottom;
    final screenHeight = mediaQuery.size.height;
    final targetHeight =
        _isFullscreen ? screenHeight : screenHeight * 0.82;

    final topMargin = _isFullscreen
        ? (safeTop > 0 ? safeTop + 8 : 34.0)
        : 12.0;
    final bottomMargin = safeBottom > 0 ? safeBottom + 10 : 16.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: targetHeight,
      decoration: BoxDecoration(
        color: Colors.white, // PURE WHITE BACKGROUND
        borderRadius: _isFullscreen
            ? BorderRadius.zero
            : const BorderRadius.only(
                topLeft: Radius.circular(28),
                topRight: Radius.circular(28),
              ),
      ),
      child: Stack(
        children: [
          // 1. FULL SCREEN PURE WHITE CANVAS
          Positioned.fill(
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: CustomPaint(
                painter: _HandwritingPainter(
                  strokes: _strokes,
                  currentStrokePoints: _currentPoints,
                  currentColor: _selectedColor,
                  currentStrokeWidth: _selectedStrokeWidth,
                  isEraser: _isEraser,
                ),
                child: Stack(
                  children: [
                    if (_strokes.isEmpty && _currentPoints.isEmpty)
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isEraser
                                  ? CupertinoIcons.trash
                                  : CupertinoIcons.hand_draw,
                              size: 44,
                              color:
                                  AppTheme.textMuted.withValues(alpha: 0.35),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _isEraser
                                  ? 'Eraser Active • Drag over strokes to erase'
                                  : 'Write, sketch, or draw notes freely ✍️',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color:
                                    AppTheme.textMuted.withValues(alpha: 0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // 2. TOP BAR: Title, Fullscreen/Resize, Tools Toggle, Save & Close
          Positioned(
            top: topMargin,
            left: 12,
            right: 12,
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.dividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.07),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Close / Back Button
                  IconButton(
                    icon: const Icon(
                      CupertinoIcons.xmark_circle_fill,
                      color: AppTheme.textMuted,
                      size: 22,
                    ),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),

                  // Inline Title Input Field
                  Expanded(
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: TextField(
                        controller: _titleController,
                        decoration: const InputDecoration(
                          hintText: 'Note Title...',
                          hintStyle: TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.textMuted,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),

                  // Resize / Fullscreen Button
                  GestureDetector(
                    onTap: () {
                      setState(() => _isFullscreen = !_isFullscreen);
                    },
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        _isFullscreen
                            ? CupertinoIcons.fullscreen_exit
                            : CupertinoIcons.fullscreen,
                        color: AppTheme.primaryPurple,
                        size: 17,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),

                  // Tools Toggle Button
                  GestureDetector(
                    onTap: () => setState(() => _showTools = !_showTools),
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: _showTools
                            ? AppTheme.primaryPurple
                            : AppTheme.primaryPurpleLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.slider_horizontal_3,
                            size: 14,
                            color: _showTools
                                ? Colors.white
                                : AppTheme.primaryPurpleDark,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _showTools ? 'Hide' : 'Tools',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: _showTools
                                  ? Colors.white
                                  : AppTheme.primaryPurpleDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),

                  // Direct Save Button
                  ElevatedButton(
                    onPressed: _isRecognizing ? null : _saveHandwrittenNote,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentPink,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 0),
                      minimumSize: const Size(54, 34),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _isRecognizing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.checkmark_alt, size: 14),
                              SizedBox(width: 3),
                              Text(
                                'Save',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),

          // 3. COLLAPSIBLE FLOATING TOOLS PANEL
          if (_showTools)
            Positioned(
              bottom: bottomMargin,
              left: 12,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.dividerColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.09),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Row 1: Pen, Eraser, 7 Color Swatches
                      Row(
                        children: [
                          // Pen Mode Button
                          _buildToolChip(
                            icon: CupertinoIcons.pen,
                            label: 'Pen',
                            isSelected: !_isEraser,
                            onTap: () => setState(() => _isEraser = false),
                          ),
                          const SizedBox(width: 6),

                          // Eraser Button
                          _buildToolChip(
                            icon: CupertinoIcons.trash,
                            label: 'Eraser',
                            isSelected: _isEraser,
                            onTap: () => setState(() => _isEraser = true),
                          ),

                          const SizedBox(width: 8),
                          Container(
                              width: 1,
                              height: 22,
                              color: AppTheme.dividerColor),
                          const SizedBox(width: 8),

                          // Color Swatches
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: _inkColors.map((c) {
                                  final isSelected =
                                      !_isEraser && _selectedColor == c;
                                  return GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _selectedColor = c;
                                        _isEraser = false;
                                      });
                                    },
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                          horizontal: 3.5),
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        color: c,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isSelected
                                              ? AppTheme.primaryPurple
                                              : Colors.black
                                                  .withValues(alpha: 0.1),
                                          width: isSelected ? 2.5 : 1,
                                        ),
                                        boxShadow: isSelected
                                            ? [
                                                BoxShadow(
                                                  color:
                                                      c.withValues(alpha: 0.45),
                                                  blurRadius: 4,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ]
                                            : null,
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Row 2: Stroke Sizes & Undo/Redo/Clear
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Stroke Widths
                          Row(
                            children: _strokeWidths.map((w) {
                              final isSelected = _selectedStrokeWidth == w;
                              return GestureDetector(
                                onTap: () =>
                                    setState(() => _selectedStrokeWidth = w),
                                child: Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? AppTheme.primaryPurpleLight
                                        : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSelected
                                          ? AppTheme.primaryPurple
                                          : AppTheme.dividerColor,
                                    ),
                                  ),
                                  child: Center(
                                    child: Container(
                                      width: w > 8 ? 16 : w * 2.2,
                                      height: w > 8 ? 6 : w,
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? AppTheme.primaryPurple
                                            : AppTheme.textMuted,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),

                          // Undo, Redo, Clear All
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(CupertinoIcons.arrow_uturn_left,
                                    size: 16),
                                color: _strokes.isNotEmpty
                                    ? AppTheme.textPrimary
                                    : AppTheme.textMuted,
                                tooltip: 'Undo',
                                onPressed: _strokes.isNotEmpty ? _undo : null,
                                constraints: const BoxConstraints(
                                    minWidth: 26, minHeight: 26),
                                padding: EdgeInsets.zero,
                              ),
                              IconButton(
                                icon: const Icon(
                                    CupertinoIcons.arrow_uturn_right,
                                    size: 16),
                                color: _undoHistory.isNotEmpty
                                    ? AppTheme.textPrimary
                                    : AppTheme.textMuted,
                                tooltip: 'Redo',
                                onPressed:
                                    _undoHistory.isNotEmpty ? _redo : null,
                                constraints: const BoxConstraints(
                                    minWidth: 26, minHeight: 26),
                                padding: EdgeInsets.zero,
                              ),
                              IconButton(
                                icon: const Icon(CupertinoIcons.clear_thick,
                                    size: 16),
                                color: _strokes.isNotEmpty
                                    ? AppTheme.accentPink
                                    : AppTheme.textMuted,
                                tooltip: 'Clear All',
                                onPressed:
                                    _strokes.isNotEmpty ? _clearCanvas : null,
                                constraints: const BoxConstraints(
                                    minWidth: 26, minHeight: 26),
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
  }

  Widget _buildToolChip({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primaryPurple : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 12,
              color: isSelected ? Colors.white : AppTheme.textPrimary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: isSelected ? Colors.white : AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom painter for multi-color strokes with highlighter transparency
class _HandwritingPainter extends CustomPainter {
  final List<HandwritingStroke> strokes;
  final List<Offset> currentStrokePoints;
  final Color currentColor;
  final double currentStrokeWidth;
  final bool isEraser;

  _HandwritingPainter({
    required this.strokes,
    required this.currentStrokePoints,
    required this.currentColor,
    required this.currentStrokeWidth,
    required this.isEraser,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Render all strokes
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;

      final paint = Paint()
        ..color = stroke.isHighlighter
            ? stroke.color.withValues(alpha: 0.4)
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

    // 2. Render active stroke
    if (!isEraser && currentStrokePoints.isNotEmpty) {
      final activePaint = Paint()
        ..color = (currentColor == const Color(0xFFFACC15))
            ? currentColor.withValues(alpha: 0.4)
            : currentColor
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = currentStrokeWidth
        ..style = PaintingStyle.stroke;

      if (currentStrokePoints.length == 1) {
        canvas.drawCircle(currentStrokePoints.first, currentStrokeWidth / 2,
            activePaint..style = PaintingStyle.fill);
      } else {
        final activePath = Path();
        activePath.moveTo(
            currentStrokePoints.first.dx, currentStrokePoints.first.dy);
        for (int i = 1; i < currentStrokePoints.length; i++) {
          activePath.lineTo(
              currentStrokePoints[i].dx, currentStrokePoints[i].dy);
        }
        canvas.drawPath(activePath, activePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HandwritingPainter oldDelegate) => true;
}
