import 'dart:io';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../models/document_item_model.dart';
import '../models/image_annotation_model.dart';
import '../models/stroke_model.dart';
import '../models/text_annotation_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/handwriting_canvas.dart';

/// Supported annotation tool types
enum AnnotationTool {
  none, // Pan & Scroll Mode
  highlighter, // Semi-transparent highlighter drawing
  straightLine, // Auto-straightened coordinate lines
  handwritingText, // Google ML Kit digital ink canvas
  addImage, // Draggable/resizable image overlay
}

class EditorScreen extends StatefulWidget {
  final String pdfPath;
  final String? fileName;

  const EditorScreen({
    super.key,
    required this.pdfPath,
    this.fileName,
  });

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  late PdfViewerController _pdfViewerController;
  final GlobalKey<SfPdfViewerState> _pdfViewerKey = GlobalKey();
  final ImagePicker _imagePicker = ImagePicker();

  // Active annotation tool state
  AnnotationTool _activeTool = AnnotationTool.none;
  Color _selectedColor = AppTheme.highlighterColors[0];
  double _strokeWidth = 14.0;

  // Drawing strokes state (Coordinates stored in PDF document space)
  final List<Stroke> _strokes = [];
  final List<Stroke> _redoHistory = [];
  Stroke? _currentStroke;

  // Digital Text Annotations state (from ML Kit Handwriting recognition)
  final List<TextAnnotation> _textAnnotations = [];
  String? _selectedTextId;

  // Image Annotations state (Draggable & Resizable Photos/Screenshots)
  final List<ImageAnnotation> _imageAnnotations = [];
  String? _selectedImageId;

  // Document page state
  int _currentPage = 1;
  int _pageCount = 1;
  bool _isDocumentLoaded = false;

  // Supabase Cloud Sync State
  bool _isSyncing = false;
  bool _isLoadingCloudData = false;

  String get _documentIdentifier =>
      widget.fileName ?? widget.pdfPath.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    _pdfViewerController = PdfViewerController();
    _pdfViewerController.addListener(_onViewerStateChanged);
    _loadAnnotationsFromSupabase();
  }

  @override
  void dispose() {
    _pdfViewerController.removeListener(_onViewerStateChanged);
    _pdfViewerController.dispose();
    super.dispose();
  }

  /// Listens to PDF scroll offset and zoom level changes to re-render overlay in real-time
  void _onViewerStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Automatically loads existing document annotations from Supabase
  Future<void> _loadAnnotationsFromSupabase() async {
    try {
      setState(() => _isLoadingCloudData = true);

      final client = Supabase.instance.client;
      final response = await client
          .from('document_annotations')
          .select()
          .eq('document_name', _documentIdentifier)
          .maybeSingle();

      if (!mounted) return;
      setState(() => _isLoadingCloudData = false);

      if (response != null) {
        final List<dynamic>? strokesJson = response['strokes_data'];
        final List<dynamic>? textsJson = response['texts_data'];
        final List<dynamic>? imagesJson = response['images_data'];

        final loadedStrokes = strokesJson
                ?.map((e) => Stroke.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            [];

        final loadedTexts = textsJson
                ?.map((e) =>
                    TextAnnotation.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            [];

        final loadedImages = imagesJson
                ?.map((e) =>
                    ImageAnnotation.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            [];

        setState(() {
          _strokes.clear();
          _strokes.addAll(loadedStrokes);

          _textAnnotations.clear();
          _textAnnotations.addAll(loadedTexts);

          _imageAnnotations.clear();
          _imageAnnotations.addAll(loadedImages);
        });

        final totalLoaded =
            loadedStrokes.length + loadedTexts.length + loadedImages.length;
        if (totalLoaded > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(CupertinoIcons.cloud_download,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 10),
                  Text('Loaded $totalLoaded annotations from Supabase Cloud ✨'),
                ],
              ),
              backgroundColor: AppTheme.primaryPurpleDark,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              margin: const EdgeInsets.all(16),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingCloudData = false);
      debugPrint('Cloud load note (offline or new doc): $e');
    }
  }

  /// Saves current document annotations (Strokes, Texts, Images) to Supabase PostgreSQL
  Future<void> _saveAnnotationsToSupabase() async {
    try {
      setState(() => _isSyncing = true);

      final client = Supabase.instance.client;
      final payload = {
        'document_name': _documentIdentifier,
        'strokes_data': _strokes.map((s) => s.toJson()).toList(),
        'texts_data': _textAnnotations.map((t) => t.toJson()).toList(),
        'images_data': _imageAnnotations.map((i) => i.toJson()).toList(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      await client
          .from('document_annotations')
          .upsert(payload, onConflict: 'document_name');

      final totalItems =
          _strokes.length + _textAnnotations.length + _imageAnnotations.length;

      // Update local persistent document entry
      await DocumentStorageService.saveOrUpdateDocument(
        DocumentItem(
          fileName: _documentIdentifier,
          filePath: widget.pdfPath,
          lastOpenedAt: DateTime.now(),
          annotationsCount: totalItems,
          isCloudSynced: true,
        ),
      );

      if (!mounted) return;
      setState(() => _isSyncing = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(CupertinoIcons.checkmark_circle_fill,
                  color: Color(0xFF10B981), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Saved $totalItems annotation${totalItems == 1 ? '' : 's'} to Supabase Cloud!',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor: AppTheme.textPrimary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSyncing = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Supabase sync error: $e'),
              ),
            ],
          ),
          backgroundColor: AppTheme.accentPinkDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// Converts screen touch position to document-space coordinates
  Offset _screenToDocument(Offset screenPoint) {
    final double zoom = _pdfViewerController.zoomLevel.clamp(0.5, 5.0);
    final Offset scroll = _pdfViewerController.scrollOffset;
    return Offset(
      (screenPoint.dx + scroll.dx) / zoom,
      (screenPoint.dy + scroll.dy) / zoom,
    );
  }

  /// Changes the active annotation tool mode
  void _onToolSelected(AnnotationTool tool) {
    setState(() {
      _activeTool = tool;
      _selectedImageId = null;
      _selectedTextId = null;
    });

    if (tool == AnnotationTool.handwritingText) {
      _launchHandwritingRecognitionDialog();
    } else if (tool == AnnotationTool.addImage) {
      _pickAndInsertImage();
    }
  }

  /// Launches Google ML Kit Handwriting Canvas Bottom Sheet
  Future<void> _launchHandwritingRecognitionDialog() async {
    final screenSize = MediaQuery.of(context).size;
    final recognizedText = await HandwritingCanvasDialog.show(context);

    if (!mounted) return;

    if (recognizedText != null && recognizedText.trim().isNotEmpty) {
      // Position the converted text in document space at center of current view
      final double zoom = _pdfViewerController.zoomLevel.clamp(0.5, 5.0);
      final Offset scroll = _pdfViewerController.scrollOffset;

      final Offset screenCenter = Offset(
        screenSize.width * 0.15,
        screenSize.height * 0.35,
      );

      final Offset docPos = Offset(
        (screenCenter.dx + scroll.dx) / zoom,
        (screenCenter.dy + scroll.dy) / zoom,
      );

      setState(() {
        _textAnnotations.add(
          TextAnnotation(
            text: recognizedText.trim(),
            position: docPos,
            fontSize: 16.0,
            color: _selectedColor == AppTheme.highlighterColors[0]
                ? AppTheme.textPrimary
                : _selectedColor,
          ),
        );
        _activeTool = AnnotationTool.none;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(CupertinoIcons.sparkles,
                  color: Color(0xFFE9D5FF), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Added: "${recognizedText.trim()}"',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
      setState(() => _activeTool = AnnotationTool.none);
    }
  }

  /// Opens gallery to insert a sticker / photo onto the PDF
  Future<void> _pickAndInsertImage() async {
    try {
      final screenSize = MediaQuery.of(context).size;
      final XFile? image =
          await _imagePicker.pickImage(source: ImageSource.gallery);

      if (!mounted) return;

      if (image != null) {
        final double zoom = _pdfViewerController.zoomLevel.clamp(0.5, 5.0);
        final Offset scroll = _pdfViewerController.scrollOffset;

        final Offset screenCenter = Offset(
          screenSize.width / 2 - 90,
          screenSize.height / 2 - 90,
        );

        final Offset docPos = Offset(
          (screenCenter.dx + scroll.dx) / zoom,
          (screenCenter.dy + scroll.dy) / zoom,
        );

        setState(() {
          _imageAnnotations.add(
            ImageAnnotation(
              imagePath: image.path,
              position: docPos,
              size: const Size(180, 180),
            ),
          );
          _activeTool = AnnotationTool.none;
        });
      } else {
        setState(() => _activeTool = AnnotationTool.none);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _activeTool = AnnotationTool.none);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load image: $e')),
      );
    }
  }

  /// Undoes the last stroke
  void _undo() {
    if (_strokes.isNotEmpty) {
      setState(() {
        final removed = _strokes.removeLast();
        _redoHistory.add(removed);
      });
    }
  }

  /// Redoes the last undone stroke
  void _redo() {
    if (_redoHistory.isNotEmpty) {
      setState(() {
        final restored = _redoHistory.removeLast();
        _strokes.add(restored);
      });
    }
  }

  /// Clears all annotations
  void _clearAnnotations() {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Clear All Annotations?'),
        content: const Text(
          'This will remove all highlights, lines, text notes, and stickers on this document.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Clear All'),
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _strokes.clear();
                _redoHistory.clear();
                _textAnnotations.clear();
                _imageAnnotations.clear();
                _selectedImageId = null;
                _selectedTextId = null;
              });
            },
          ),
        ],
      ),
    );
  }

  /// Deletes a specific image sticker
  void _deleteImageAnnotation(String id) {
    setState(() {
      _imageAnnotations.removeWhere((img) => img.id == id);
      _selectedImageId = null;
    });
  }

  /// Deletes a specific digital text note
  void _deleteTextAnnotation(String id) {
    setState(() {
      _textAnnotations.removeWhere((txt) => txt.id == id);
      _selectedTextId = null;
    });
  }

  /// Edits an existing digital text annotation
  void _editTextAnnotation(TextAnnotation annotation) {
    final controller = TextEditingController(text: annotation.text);
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Edit Note'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12.0),
          child: CupertinoTextField(
            controller: controller,
            maxLines: 4,
            autofocus: true,
            style: const TextStyle(fontSize: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.dividerColor),
            ),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                setState(() {
                  annotation.text = controller.text.trim();
                });
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = widget.fileName ?? 'Study Document';
    final totalAnnotationsCount =
        _strokes.length + _textAnnotations.length + _imageAnnotations.length;

    final double zoom = _pdfViewerController.zoomLevel.clamp(0.5, 5.0);
    final Offset scroll = _pdfViewerController.scrollOffset;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            // ==========================================
            // BASE LAYER: Syncfusion PDF Viewer
            // ==========================================
            Positioned.fill(
              child: SfPdfViewer.file(
                File(widget.pdfPath),
                key: _pdfViewerKey,
                controller: _pdfViewerController,
                canShowScrollHead: false,
                canShowScrollStatus: false,
                canShowPaginationDialog: false,
                enableDoubleTapZooming: _activeTool == AnnotationTool.none,
                onDocumentLoaded: (PdfDocumentLoadedDetails details) {
                  setState(() {
                    _pageCount = details.document.pages.count;
                    _isDocumentLoaded = true;
                  });
                },
                onPageChanged: (PdfPageChangedDetails details) {
                  setState(() {
                    _currentPage = details.newPageNumber;
                  });
                },
                onZoomLevelChanged: (PdfZoomDetails details) {
                  if (mounted) {
                    setState(() {});
                  }
                },
              ),
            ),

            // ==========================================
            // ANNOTATION LAYER: GestureDetector & CustomPaint
            // (Document-space coordinate bound overlay)
            // ==========================================
            Positioned.fill(
              child: IgnorePointer(
                // In 'none' mode, let gestures pass through to PDF Viewer for pan & pinch-zoom
                ignoring: _activeTool == AnnotationTool.none,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: (DragStartDetails details) {
                    if (_activeTool == AnnotationTool.highlighter ||
                        _activeTool == AnnotationTool.straightLine) {
                      final docPoint = _screenToDocument(details.localPosition);
                      final currentZoom =
                          _pdfViewerController.zoomLevel.clamp(0.5, 5.0);

                      setState(() {
                        _redoHistory.clear();
                        _currentStroke = Stroke(
                          points: [docPoint],
                          color: _selectedColor,
                          strokeWidth: _strokeWidth / currentZoom,
                          isStraightLine:
                              _activeTool == AnnotationTool.straightLine,
                        );
                      });
                    }
                  },
                  onPanUpdate: (DragUpdateDetails details) {
                    if (_currentStroke != null) {
                      final docPoint = _screenToDocument(details.localPosition);
                      setState(() {
                        _currentStroke!.points.add(docPoint);
                      });
                    }
                  },
                  onPanEnd: (DragEndDetails details) {
                    if (_currentStroke != null) {
                      setState(() {
                        _strokes.add(_currentStroke!);
                        _currentStroke = null;
                      });
                    }
                  },
                  onPanCancel: () {
                    if (_currentStroke != null) {
                      setState(() {
                        _currentStroke = null;
                      });
                    }
                  },
                  child: CustomPaint(
                    painter: BaseAnnotationPainter(
                      strokes: _strokes,
                      currentStroke: _currentStroke,
                      activeTool: _activeTool,
                      zoomLevel: zoom,
                      scrollOffset: scroll,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),

            // ==========================================
            // IMAGE ANNOTATION LAYER: Scaled & Positioned Photos
            // ==========================================
            ..._imageAnnotations.map((annotation) {
              final screenX = annotation.position.dx * zoom - scroll.dx;
              final screenY = annotation.position.dy * zoom - scroll.dy;
              final screenWidth = annotation.size.width * zoom;
              final screenHeight = annotation.size.height * zoom;

              return Positioned(
                left: screenX,
                top: screenY,
                child: _buildDraggableResizableImageWidget(
                  annotation,
                  zoom: zoom,
                  displayWidth: screenWidth,
                  displayHeight: screenHeight,
                ),
              );
            }),

            // ==========================================
            // TEXT ANNOTATION LAYER: Scaled Digital Text Notes
            // ==========================================
            ..._textAnnotations.map((annotation) {
              final screenX = annotation.position.dx * zoom - scroll.dx;
              final screenY = annotation.position.dy * zoom - scroll.dy;

              return Positioned(
                left: screenX,
                top: screenY,
                child: _buildDraggableTextWidget(
                  annotation,
                  zoom: zoom,
                ),
              );
            }),

            // Cloud Data Loading Shimmer / Banner
            if (_isLoadingCloudData)
              Positioned(
                top: MediaQuery.of(context).padding.top + 60,
                left: 20,
                right: 20,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWhite.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: AppTheme.softShadow,
                      border: Border.all(color: AppTheme.dividerColor),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.primaryPurple,
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Loading cloud annotations...',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primaryPurpleDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ==========================================
            // TOP BAR: Navigation, Document Title & Page Status
            // ==========================================
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildTopAppBar(displayName, totalAnnotationsCount),
            ),

            // ==========================================
            // FLOATING TOOLBAR: Bottom Annotation Bar
            // ==========================================
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Secondary Color/Stroke Palette
                  if (_activeTool == AnnotationTool.highlighter ||
                      _activeTool == AnnotationTool.straightLine)
                    _buildColorPickerSubBar(),

                  const SizedBox(height: 10),

                  // Main Floating Annotation Toolbar
                  _buildFloatingBottomToolbar(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Draggable & Resizable Image Sticker Widget with Zoom Scaling
  Widget _buildDraggableResizableImageWidget(
    ImageAnnotation annotation, {
    required double zoom,
    required double displayWidth,
    required double displayHeight,
  }) {
    final isSelected = _selectedImageId == annotation.id;

    return GestureDetector(
      onPanUpdate: (DragUpdateDetails details) {
        setState(() {
          annotation.position += details.delta / zoom;
          _selectedImageId = annotation.id;
          _selectedTextId = null;
        });
      },
      onTap: () {
        setState(() {
          _selectedImageId = isSelected ? null : annotation.id;
          _selectedTextId = null;
        });
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Base Image Container
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: displayWidth.clamp(30.0, 1200.0),
            height: displayHeight.clamp(30.0, 1200.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16 * zoom.clamp(0.8, 1.5)),
              border: Border.all(
                color: isSelected
                    ? AppTheme.primaryPurple
                    : Colors.white.withValues(alpha: 0.9),
                width: isSelected ? 2.5 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: isSelected
                      ? AppTheme.primaryPurple.withValues(alpha: 0.35)
                      : const Color(0xFF2D2640).withValues(alpha: 0.12),
                  blurRadius: isSelected ? 16 : 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14 * zoom.clamp(0.8, 1.5)),
              child: Image.file(
                File(annotation.imagePath),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: AppTheme.primaryPurpleLight,
                  child: const Center(
                    child: Icon(
                      Icons.broken_image_rounded,
                      color: AppTheme.textMuted,
                      size: 32,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Top Action Floating Bar (Drag badge + Delete button)
          if (isSelected)
            Positioned(
              top: -38,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.dividerColor),
                    boxShadow: AppTheme.softShadow,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        CupertinoIcons.move,
                        size: 13,
                        color: AppTheme.primaryPurple,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Image',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryPurple,
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _deleteImageAnnotation(annotation.id),
                        child: const Icon(
                          CupertinoIcons.trash,
                          size: 14,
                          color: AppTheme.accentPink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Bottom-Right Corner Resize Grip Handle
          if (isSelected)
            Positioned(
              right: -12,
              bottom: -12,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (DragUpdateDetails details) {
                  setState(() {
                    final newWidth = (annotation.size.width + details.delta.dx / zoom)
                        .clamp(40.0, 800.0);
                    final newHeight = (annotation.size.height + details.delta.dy / zoom)
                        .clamp(40.0, 800.0);
                    annotation.size = Size(newWidth, newHeight);
                  });
                },
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primaryPurple.withValues(alpha: 0.45),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(
                    CupertinoIcons.arrow_down_right_arrow_up_left,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Draggable Digital Text Note Widget with Zoom Scaling
  Widget _buildDraggableTextWidget(
    TextAnnotation annotation, {
    required double zoom,
  }) {
    final isSelected = _selectedTextId == annotation.id;

    return GestureDetector(
      onPanUpdate: (DragUpdateDetails details) {
        setState(() {
          annotation.position += details.delta / zoom;
          _selectedTextId = annotation.id;
          _selectedImageId = null;
        });
      },
      onTap: () {
        setState(() {
          _selectedTextId = isSelected ? null : annotation.id;
          _selectedImageId = null;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: EdgeInsets.symmetric(
          horizontal: 12 * zoom.clamp(0.8, 1.6),
          vertical: 8 * zoom.clamp(0.8, 1.6),
        ),
        constraints: BoxConstraints(maxWidth: 280 * zoom),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(14 * zoom.clamp(0.8, 1.5)),
          border: Border.all(
            color: isSelected ? AppTheme.primaryPurple : AppTheme.dividerColor,
            width: isSelected ? 2.0 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? AppTheme.primaryPurple.withValues(alpha: 0.25)
                  : const Color(0xFF2D2640).withValues(alpha: 0.08),
              blurRadius: isSelected ? 12 : 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Selected Actions Toolbar (Edit / Delete / Drag Handle)
            if (isSelected)
              Padding(
                padding: const EdgeInsets.only(bottom: 6.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.move,
                      size: 13,
                      color: AppTheme.primaryPurple,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Drag',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryPurple,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _editTextAnnotation(annotation),
                      child: const Icon(
                        CupertinoIcons.pencil,
                        size: 14,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _deleteTextAnnotation(annotation.id),
                      child: const Icon(
                        CupertinoIcons.trash,
                        size: 14,
                        color: AppTheme.accentPink,
                      ),
                    ),
                  ],
                ),
              ),

            // Converted Text
            Text(
              annotation.text,
              style: TextStyle(
                fontSize: (annotation.fontSize * zoom).clamp(8.0, 60.0),
                fontWeight: FontWeight.w600,
                color: annotation.color,
                height: 1.3,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Elegant glassmorphic Top App Bar with Supabase Save Action
  Widget _buildTopAppBar(String title, int totalAnnotationsCount) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 8,
            bottom: 12,
            left: 16,
            right: 16,
          ),
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.88),
            border: Border(
              bottom: BorderSide(
                color: AppTheme.dividerColor.withValues(alpha: 0.8),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.textPrimary.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              // Back Button
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.primaryPurpleLight.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    CupertinoIcons.chevron_back,
                    color: AppTheme.primaryPurple,
                    size: 20,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 10),

              // Title and Page Badge
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryPurpleLight,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _isDocumentLoaded
                                  ? 'Page $_currentPage of $_pageCount'
                                  : 'Loading...',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primaryPurpleDark,
                              ),
                            ),
                          ),
                          if (_activeTool != AnnotationTool.none) ...[
                            const SizedBox(width: 6),
                            Text(
                              '• ${_getToolName(_activeTool)}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.accentPinkDark,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (totalAnnotationsCount > 0) ...[
                            const SizedBox(width: 6),
                            Text(
                              '($totalAnnotationsCount)',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.textMuted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),

              // Undo Button
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(
                  CupertinoIcons.arrow_uturn_left,
                  color: _strokes.isNotEmpty
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted.withValues(alpha: 0.4),
                  size: 18,
                ),
                tooltip: 'Undo stroke',
                onPressed: _strokes.isNotEmpty ? _undo : null,
              ),

              // Redo Button
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(
                  CupertinoIcons.arrow_uturn_right,
                  color: _redoHistory.isNotEmpty
                      ? AppTheme.textPrimary
                      : AppTheme.textMuted.withValues(alpha: 0.4),
                  size: 18,
                ),
                tooltip: 'Redo stroke',
                onPressed: _redoHistory.isNotEmpty ? _redo : null,
              ),

              // Clear Annotations Button
              if (totalAnnotationsCount > 0)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 32),
                  icon: const Icon(
                    CupertinoIcons.trash,
                    color: AppTheme.accentPink,
                    size: 17,
                  ),
                  tooltip: 'Clear Annotations',
                  onPressed: _clearAnnotations,
                ),

              // Supabase Cloud Save Button
              Container(
                margin: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accentPink.withValues(alpha: 0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _isSyncing ? null : _saveAnnotationsToSupabase,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isSyncing) ...[
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              'Saving',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ] else ...[
                            const Icon(
                              CupertinoIcons.cloud_upload_fill,
                              color: Colors.white,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'Save',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Floating Annotation Toolbar at bottom
  Widget _buildFloatingBottomToolbar() {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(36),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.surfaceWhite.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(36),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.8),
                width: 1.5,
              ),
              boxShadow: AppTheme.floatingToolbarShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Scroll / Pan Mode (Hand)
                _buildToolButton(
                  tool: AnnotationTool.none,
                  icon: CupertinoIcons.hand_draw,
                  label: 'Navigate',
                  tooltip: 'Pan & Pinch Zoom Document',
                ),

                const SizedBox(width: 4),
                _buildVerticalDivider(),
                const SizedBox(width: 4),

                // 1. Highlighter
                _buildToolButton(
                  tool: AnnotationTool.highlighter,
                  icon: CupertinoIcons.pencil_outline,
                  label: 'Highlighter',
                  tooltip: 'Freehand Highlighter',
                ),

                const SizedBox(width: 4),

                // 2. Straight Line
                _buildToolButton(
                  tool: AnnotationTool.straightLine,
                  icon: CupertinoIcons.line_horizontal_3_decrease,
                  label: 'Straight Line',
                  tooltip: 'Auto-Straightened Line',
                ),

                const SizedBox(width: 4),

                // 3. Write Text (ML Kit Handwriting Recognizer)
                _buildToolButton(
                  tool: AnnotationTool.handwritingText,
                  icon: CupertinoIcons.textformat,
                  label: 'Write Text',
                  tooltip: 'Handwriting to Text',
                ),

                const SizedBox(width: 4),

                // 4. Add Image (Gallery Picker + Resize)
                _buildToolButton(
                  tool: AnnotationTool.addImage,
                  icon: CupertinoIcons.photo,
                  label: 'Add Image',
                  tooltip: 'Insert Image / Screenshot',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Single tool icon button with active animations
  Widget _buildToolButton({
    required AnnotationTool tool,
    required IconData icon,
    required String label,
    required String tooltip,
  }) {
    final isSelected = _activeTool == tool;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: () => _onToolSelected(tool),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: isSelected ? 14 : 10,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              gradient: isSelected
                  ? const LinearGradient(
                      colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              color: isSelected ? null : Colors.transparent,
              borderRadius: BorderRadius.circular(28),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: AppTheme.primaryPurple.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isSelected ? Colors.white : AppTheme.textSecondary,
                ),
                if (isSelected) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Secondary floating color palette picker with stroke width options
  Widget _buildColorPickerSubBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.dividerColor),
            boxShadow: AppTheme.softShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Color Dots
              ...AppTheme.highlighterColors.map((color) {
                final isSelected = _selectedColor == color;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = color),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 1.0),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? AppTheme.textPrimary : Colors.white,
                        width: isSelected ? 2.5 : 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                );
              }),

              const SizedBox(width: 6),
              _buildVerticalDivider(),
              const SizedBox(width: 6),

              // Stroke Width Presets (Thin, Medium, Thick)
              _buildStrokeSizePreset(
                label: 'S',
                width: _activeTool == AnnotationTool.straightLine ? 2.5 : 10.0,
              ),
              _buildStrokeSizePreset(
                label: 'M',
                width: _activeTool == AnnotationTool.straightLine ? 4.5 : 16.0,
              ),
              _buildStrokeSizePreset(
                label: 'L',
                width: _activeTool == AnnotationTool.straightLine ? 7.0 : 24.0,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStrokeSizePreset({
    required String label,
    required double width,
  }) {
    final isSelected = (_strokeWidth - width).abs() < 0.5;

    return GestureDetector(
      onTap: () => setState(() => _strokeWidth = width),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primaryPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: isSelected ? Colors.white : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalDivider() {
    return Container(
      width: 1,
      height: 22,
      color: AppTheme.dividerColor,
    );
  }

  String _getToolName(AnnotationTool tool) {
    switch (tool) {
      case AnnotationTool.highlighter:
        return 'Highlighter';
      case AnnotationTool.straightLine:
        return 'Straight Line';
      case AnnotationTool.handwritingText:
        return 'Handwriting Text';
      case AnnotationTool.addImage:
        return 'Image Insert';
      case AnnotationTool.none:
        return 'Pan & Zoom';
    }
  }
}

/// Annotation Painter rendering freehand highlighter curves and auto-straightened lines
/// with transformation matrix support matching the PDF Viewer's pan and zoom
class BaseAnnotationPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final AnnotationTool activeTool;
  final double zoomLevel;
  final Offset scrollOffset;

  BaseAnnotationPainter({
    required this.strokes,
    required this.currentStroke,
    required this.activeTool,
    required this.zoomLevel,
    required this.scrollOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // Clip to canvas size to prevent bleeding outside viewport
    canvas.clipRect(Offset.zero & size);

    // Transform canvas coordinate space to match PDF Viewer scroll & zoom
    canvas.translate(-scrollOffset.dx, -scrollOffset.dy);
    canvas.scale(zoomLevel, zoomLevel);

    // 1. Draw all committed historical strokes
    for (final stroke in strokes) {
      _renderStroke(canvas, stroke);
    }

    // 2. Draw currently active drag stroke (with live preview)
    if (currentStroke != null) {
      _renderStroke(canvas, currentStroke!);
    }

    canvas.restore();
  }

  void _renderStroke(Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (stroke.isStraightLine) {
      // Auto-straightened Line: Direct line from first coordinate to last coordinate
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first,
          stroke.strokeWidth / 2,
          paint..style = PaintingStyle.fill,
        );
      } else {
        canvas.drawLine(stroke.points.first, stroke.points.last, paint);
      }
    } else {
      // Freehand Highlighter: Smooth Bezier curve path
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first,
          stroke.strokeWidth / 2,
          paint..style = PaintingStyle.fill,
        );
      } else {
        final path = Path();
        path.moveTo(stroke.points[0].dx, stroke.points[0].dy);

        for (int i = 1; i < stroke.points.length - 1; i++) {
          final p0 = stroke.points[i];
          final p1 = stroke.points[i + 1];
          final midX = (p0.dx + p1.dx) / 2;
          final midY = (p0.dy + p1.dy) / 2;
          path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
        }

        if (stroke.points.length > 1) {
          path.lineTo(stroke.points.last.dx, stroke.points.last.dy);
        }

        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BaseAnnotationPainter oldDelegate) {
    return true; // Continuously repaint on gesture & zoom updates for 60/120fps precision
  }
}
