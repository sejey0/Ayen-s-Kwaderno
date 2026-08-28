import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;
import '../models/handwriting_note_model.dart';
import '../services/document_storage_service.dart';
import '../services/gemini_handwriting_service.dart';
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

  Map<String, dynamic> toJson() {
    return {
      'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      'color': color.toARGB32(),
      'strokeWidth': strokeWidth,
      'isHighlighter': isHighlighter,
    };
  }

  factory HandwritingStroke.fromJson(Map<String, dynamic> json) {
    final rawPts = json['points'] as List<dynamic>? ?? [];
    final pts = rawPts.map((pt) {
      final m = pt as Map<String, dynamic>;
      return Offset(
        (m['x'] as num).toDouble(),
        (m['y'] as num).toDouble(),
      );
    }).toList();

    return HandwritingStroke(
      points: pts,
      color: Color(json['color'] as int? ?? 0xFF1E293B),
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 3.5,
      isHighlighter: json['isHighlighter'] as bool? ?? false,
    );
  }
}

/// Full screen pure white canvas studio for handwritten notes with 2-Page Smart Note support:
/// - Page 1: Real Handwritten Drawing Canvas
/// - Page 2: AI Converted Digital Text
class HandwritingCanvasDialog extends StatefulWidget {
  final String languageCode;
  final HandwritingNote? existingNote;

  const HandwritingCanvasDialog({
    super.key,
    this.languageCode = 'en',
    this.existingNote,
  });

  /// Static helper to launch the dialog and return the created/saved HandwritingNote
  static Future<HandwritingNote?> show(BuildContext context,
      {HandwritingNote? existingNote}) {
    return showModalBottomSheet<HandwritingNote>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) =>
          HandwritingCanvasDialog(existingNote: existingNote),
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
  final TextEditingController _convertedTextController =
      TextEditingController();

  // 2-Page Navigation: 0 = Page 1 (Drawing Canvas), 1 = Page 2 (Converted Text)
  int _activePageIndex = 0;

  // Full Screen / Resize state
  bool _isFullscreen = true;
  bool _showTools = true;

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

  @override
  void initState() {
    super.initState();
    _recognizer =
        mlkit.DigitalInkRecognizer(languageCode: widget.languageCode);
    _initializeModel();

    // Preload existing note if editing
    if (widget.existingNote != null) {
      _titleController.text = widget.existingNote!.title;
      if (widget.existingNote!.strokesJson != null) {
        for (final sJson in widget.existingNote!.strokesJson!) {
          _strokes.add(HandwritingStroke.fromJson(sJson));
        }
      }
      final existingContent = widget.existingNote!.content;
      if (existingContent.isNotEmpty &&
          !existingContent.startsWith('Handwritten drawing (')) {
        _convertedTextController.text = existingContent;
      }
    }
  }

  @override
  void dispose() {
    try {
      _recognizer.close().catchError((_) {});
    } catch (_) {}
    _titleController.dispose();
    _convertedTextController.dispose();
    super.dispose();
  }

  Future<void> _initializeModel() async {
    try {
      final isDownloaded =
          await _modelManager.isModelDownloaded(widget.languageCode);
      if (!isDownloaded) {
        await _modelManager.downloadModel(widget.languageCode);
      }
    } catch (_) {}
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

  /// Converts handwritten ink strokes into digital recognized text using Gemini Vision AI / ML Kit
  Future<String> _recognizeHandwriting() async {
    if (_strokes.isEmpty) {
      return '';
    }

    // 1. Try Ultra-Accurate Google Gemini Multimodal Vision AI first
    try {
      if (mounted) setState(() => _isRecognizing = true);
      final geminiResult =
          await GeminiHandwritingService.transcribeWithGemini(_strokes);
      if (geminiResult != null && geminiResult.trim().isNotEmpty) {
        if (mounted) setState(() => _isRecognizing = false);
        return geminiResult.trim();
      }
    } catch (e) {
      debugPrint('Gemini vision attempt notice: $e');
    }

    // 2. On-Device Google ML Kit Digital Ink Recognition fallback
    try {
      final isDownloaded =
          await _modelManager.isModelDownloaded(widget.languageCode);
      if (!isDownloaded) {
        if (mounted) setState(() => _isRecognizing = true);
        await _modelManager.downloadModel(widget.languageCode);
      }
    } catch (e) {
      debugPrint('Model download check notice: $e');
    }

    // Build fresh ML Kit Ink with normalized monotonic millisecond timestamps
    final ink = mlkit.Ink();
    int timeMs = 0;
    for (final stroke in _strokes) {
      if (stroke.points.isEmpty) continue;
      final mlStroke = mlkit.Stroke();
      for (final pt in stroke.points) {
        mlStroke.points.add(
          mlkit.StrokePoint(
            x: pt.dx,
            y: pt.dy,
            t: timeMs += 15,
          ),
        );
      }
      ink.strokes.add(mlStroke);
    }

    try {
      if (mounted) setState(() => _isRecognizing = true);
      final candidates = await _recognizer.recognize(ink);
      if (mounted) setState(() => _isRecognizing = false);

      if (candidates.isNotEmpty) {
        final recognizedText = candidates.first.text.trim();
        debugPrint('Recognized ML Kit Text: $recognizedText');
        return recognizedText;
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() => _isRecognizing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Full app restart required: Please restart run.bat once to enable native ML Kit recognition.',
            ),
            backgroundColor: Color(0xFFE11D48),
            duration: Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Digital Ink Recognition error: $e');
      if (mounted) setState(() => _isRecognizing = false);
    }
    return '';
  }

  /// Converts handwriting while writing and switches to Page 2
  Future<void> _convertAndShowTextPage() async {
    if (_strokes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please write or draw something on the canvas first!'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final recognized = await _recognizeHandwriting();
    if (!mounted) return;

    if (recognized.isNotEmpty) {
      setState(() {
        _convertedTextController.text = recognized;
        _activePageIndex = 1; // Switch to Page 2: Converted Text
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(CupertinoIcons.sparkles,
                  color: Color(0xFFFACC15), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Recognized: "$recognized"'),
              ),
            ],
          ),
          backgroundColor: AppTheme.primaryPurpleDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      setState(() {
        _activePageIndex = 1;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not detect text clearly yet. You can keep writing or type notes!'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _showAiKeyDialog() async {
    final activeKey = await GeminiHandwritingService.getActiveApiKey() ?? '';
    final keyController = TextEditingController(text: activeKey);

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(CupertinoIcons.sparkles, color: AppTheme.primaryPurple),
            SizedBox(width: 8),
            Text(
              'Gemini Vision AI',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your free Google Gemini API Key from Google AI Studio (aistudio.google.com) for ultra-accurate handwriting & cursive transcription:',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyController,
              decoration: InputDecoration(
                hintText: 'AIzaSy...',
                labelText: 'Gemini API Key',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await GeminiHandwritingService.setCustomApiKey(
                  keyController.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Gemini API Key updated!'),
                  backgroundColor: AppTheme.primaryPurpleDark,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Save Key'),
          ),
        ],
      ),
    );
  }

  /// Saves BOTH Page 1 (Handwritten Drawing) and Page 2 (Converted Text) in 1 note file
  Future<void> _saveHandwrittenNote() async {
    final title = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : 'Note ${DateTime.now().month}/${DateTime.now().day}';

    String textContent = _convertedTextController.text.trim();
    if (textContent.isEmpty && _strokes.isNotEmpty) {
      final recognized = await _recognizeHandwriting();
      textContent = recognized.isNotEmpty ? recognized : '';
    }

    final newNote = HandwritingNote(
      id: widget.existingNote?.id ??
          'note_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      content: textContent,
      createdAt: widget.existingNote?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      paletteIndex: widget.existingNote?.paletteIndex ??
          (DateTime.now().millisecond % 5),
      isCloudSynced: false,
      isHandwritten: true,
      strokesJson: _strokes.map((s) => s.toJson()).toList(),
    );

    await DocumentStorageService.saveOrUpdateHandwritingNote(newNote);

    if (!mounted) return;
    Navigator.of(context).pop(newNote);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(CupertinoIcons.checkmark_circle_fill,
                color: Color(0xFF10B981), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Saved "$title" (2 Pages: Drawing + Text)',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        backgroundColor: AppTheme.textPrimary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
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
        _isFullscreen ? screenHeight : screenHeight * 0.85;

    final topMargin = _isFullscreen
        ? (safeTop > 0 ? safeTop + 8 : 34.0)
        : 12.0;
    final bottomMargin = safeBottom > 0 ? safeBottom + 10 : 16.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: targetHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: _isFullscreen
            ? BorderRadius.zero
            : const BorderRadius.only(
                topLeft: Radius.circular(28),
                topRight: Radius.circular(28),
              ),
      ),
      child: Stack(
        children: [
          // ==============================================================
          // PAGE BODY: PAGE 1 (DRAWING CANVAS) OR PAGE 2 (CONVERTED TEXT)
          // ==============================================================
          if (_activePageIndex == 0)
            // PAGE 1: Pure White Drawing Space
            Positioned.fill(
              child: GestureDetector(
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: CustomPaint(
                  painter: HandwritingCanvasPainter(
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
                                color: AppTheme.textMuted
                                    .withValues(alpha: 0.35),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _isEraser
                                    ? 'Eraser Active • Drag over strokes to erase'
                                    : 'Write, sketch, or draw notes freely',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textMuted
                                      .withValues(alpha: 0.55),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            )
          else
            // PAGE 2: AI Converted Digital Text View
            Positioned.fill(
              child: Container(
                color: const Color(0xFFF8FAFC),
                padding: EdgeInsets.fromLTRB(
                    16, topMargin + 56, 16, bottomMargin + 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Converted Text Banner
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            AppTheme.primaryPurpleLight,
                            Color(0xFFEDE9FE),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppTheme.primaryPurple
                              .withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(CupertinoIcons.sparkles,
                              color: AppTheme.primaryPurple, size: 18),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Page 2: Converted Digital Text',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.primaryPurpleDark,
                                  ),
                                ),
                                Text(
                                  'Recognized text from Page 1. Edit or copy anytime!',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Re-convert button
                          GestureDetector(
                            onTap: _convertAndShowTextPage,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppTheme.primaryPurple
                                        .withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_isRecognizing)
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.primaryPurple,
                                      ),
                                    )
                                  else ...[
                                    const Icon(CupertinoIcons.arrow_2_circlepath,
                                        size: 12,
                                        color: AppTheme.primaryPurple),
                                    const SizedBox(width: 4),
                                    const Text(
                                      'Re-convert',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.primaryPurple,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),

                          // AI Settings Button
                          GestureDetector(
                            onTap: _showAiKeyDialog,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppTheme.primaryPurple
                                        .withValues(alpha: 0.3)),
                              ),
                              child: const Icon(
                                CupertinoIcons.gear_alt,
                                size: 14,
                                color: AppTheme.primaryPurple,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Editable Text Area
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppTheme.dividerColor),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: TextField(
                          controller: _convertedTextController,
                          maxLines: null,
                          expands: true,
                          decoration: const InputDecoration(
                            hintText:
                                'Converted text will appear here. You can also type notes or study summaries...',
                            hintStyle: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                          ),
                          style: const TextStyle(
                            fontSize: 14.5,
                            color: AppTheme.textPrimary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Bottom Quick Actions for Page 2
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Switch back to Drawing Page
                        OutlinedButton.icon(
                          onPressed: () =>
                              setState(() => _activePageIndex = 0),
                          icon: const Icon(CupertinoIcons.pencil, size: 14),
                          label: const Text('Page 1: Drawing Canvas'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primaryPurple,
                            side: const BorderSide(
                                color: AppTheme.primaryPurple),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),

                        // Copy Text
                        ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                                text: _convertedTextController.text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Copied converted text!'),
                                duration: Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          icon: const Icon(CupertinoIcons.doc_on_clipboard,
                              size: 14),
                          label: const Text('Copy Text'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryPurple,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // ==============================================================
          // TOP BAR: Navigation, Title, 2-Page Switcher, Convert, Save
          // ==============================================================
          Positioned(
            top: topMargin,
            left: 12,
            right: 12,
            child: Container(
              height: 50,
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
                        const BoxConstraints(minWidth: 30, minHeight: 30),
                    padding: EdgeInsets.zero,
                  ),

                  // Inline Title Input Field
                  Expanded(
                    flex: 3,
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
                            fontSize: 12,
                            color: AppTheme.textMuted,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),

                  // 2-PAGE SWITCHER PILL (Page 1: Drawing | Page 2: Text)
                  Container(
                    height: 34,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () => setState(() => _activePageIndex = 0),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: _activePageIndex == 0
                                  ? AppTheme.primaryPurple
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              CupertinoIcons.pencil,
                              size: 14,
                              color: _activePageIndex == 0
                                  ? Colors.white
                                  : AppTheme.textSecondary,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            if (_convertedTextController.text.trim().isEmpty &&
                                _strokes.isNotEmpty) {
                              _convertAndShowTextPage();
                            } else {
                              setState(() => _activePageIndex = 1);
                            }
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: _activePageIndex == 1
                                  ? AppTheme.primaryPurple
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              CupertinoIcons.doc_text,
                              size: 14,
                              color: _activePageIndex == 1
                                  ? Colors.white
                                  : AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),

                  // CONVERT TO TEXT BUTTON (Runs ML Kit Recognition)
                  GestureDetector(
                    onTap: _isRecognizing ? null : _convertAndShowTextPage,
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryPurple
                                .withValues(alpha: 0.25),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isRecognizing)
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          else ...[
                            const Icon(CupertinoIcons.sparkles,
                                size: 13, color: Colors.white),
                            const SizedBox(width: 4),
                            const Text(
                              'Convert',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ],
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
                        size: 16,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),

                  // Tools Toggle Button (when on drawing canvas)
                  if (_activePageIndex == 0) ...[
                    GestureDetector(
                      onTap: () => setState(() => _showTools = !_showTools),
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 7),
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
                              size: 13,
                              color: _showTools
                                  ? Colors.white
                                  : AppTheme.primaryPurpleDark,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _showTools ? 'Hide' : 'Tools',
                              style: TextStyle(
                                fontSize: 10.5,
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
                    const SizedBox(width: 5),
                  ],

                  // Direct Save Button (Saves BOTH Page 1 & Page 2)
                  ElevatedButton(
                    onPressed: _isRecognizing ? null : _saveHandwrittenNote,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      elevation: 0,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(54, 34),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryPurple
                                .withValues(alpha: 0.25),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        height: 34,
                        alignment: Alignment.center,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.checkmark_alt,
                                size: 14, color: Colors.white),
                            SizedBox(width: 3),
                            Text(
                              'Save',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
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
          ),

          // ==============================================================
          // COLLAPSIBLE FLOATING TOOLS PANEL (VISIBLE ON DRAWING PAGE)
          // ==============================================================
          if (_showTools && _activePageIndex == 0)
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
class HandwritingCanvasPainter extends CustomPainter {
  final List<HandwritingStroke> strokes;
  final List<Offset> currentStrokePoints;
  final Color currentColor;
  final double currentStrokeWidth;
  final bool isEraser;
  final bool fitThumbnail;

  HandwritingCanvasPainter({
    required this.strokes,
    this.currentStrokePoints = const [],
    this.currentColor = const Color(0xFF1E293B),
    this.currentStrokeWidth = 3.5,
    this.isEraser = false,
    this.fitThumbnail = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty && currentStrokePoints.isEmpty) return;

    // Optional scale matrix for thumbnail preview
    if (fitThumbnail && strokes.isNotEmpty) {
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

      final strokeWidth = maxX - minX;
      final strokeHeight = maxY - minY;

      if (strokeWidth > 10 && strokeHeight > 10) {
        final scaleX = (size.width - 24) / strokeWidth;
        final scaleY = (size.height - 24) / strokeHeight;
        final scale = scaleX < scaleY ? scaleX : scaleY;

        canvas.save();
        canvas.translate(
          (size.width - strokeWidth * scale) / 2 - minX * scale,
          (size.height - strokeHeight * scale) / 2 - minY * scale,
        );
        canvas.scale(scale);
      }
    }

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
        ..color = (currentStrokeWidth >= 8.0 || currentColor.a < 0.95)
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

    if (fitThumbnail && strokes.isNotEmpty) {
      try {
        canvas.restore();
      } catch (_) {}
    }
  }

  @override
  bool shouldRepaint(covariant HandwritingCanvasPainter oldDelegate) => true;
}
