import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_pdfviewer_platform_interface/pdfviewer_platform_interface.dart';
import '../models/document_item_model.dart';
import '../models/image_annotation_model.dart';
import '../models/stroke_model.dart';
import '../models/text_annotation_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/handwriting_canvas.dart';

/// Supported annotation tool types
enum AnnotationTool {
  none, // Pan & Zoom Navigation Mode
  highlighter, // Semi-transparent highlighter drawing
  straightLine, // Auto-straightened coordinate lines
  handwritingText, // Google ML Kit digital ink canvas
  addImage, // Draggable/resizable image overlay
}

/// Cloud and Local Synchronization status
enum SyncStatus {
  synced, // Successfully synced to Supabase Cloud
  syncing, // Actively uploading to Supabase
  savedLocally, // Saved to local storage, pending upload
  offline, // Device offline, stored securely in local cache
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
  final TransformationController _transformationController =
      TransformationController();
  final ImagePicker _imagePicker = ImagePicker();

  // Active annotation tool state
  AnnotationTool _activeTool = AnnotationTool.none;
  Color _selectedColor = AppTheme.highlighterColors[0];
  double _strokeWidth = 14.0;

  // Drawing strokes state
  final List<Stroke> _strokes = [];
  final List<Stroke> _redoHistory = [];
  Stroke? _currentStroke;

  // Digital Text Annotations state (from ML Kit Handwriting recognition)
  final List<TextAnnotation> _textAnnotations = [];
  String? _selectedTextId;

  // Image Annotations state (Draggable & Resizable Photos/Screenshots)
  final List<ImageAnnotation> _imageAnnotations = [];
  String? _selectedImageId;

  // PDF Page Engine State
  late final String _documentId;
  int _currentPage = 1;
  int _pageCount = 1;
  double _pageWidth = 595.0;
  double _pageHeight = 842.0;
  ui.Image? _renderedPageUiImage;
  bool _isDocumentLoaded = false;
  bool _isLoadingPage = false;

  // Auto-Save & Synchronization State
  SyncStatus _syncStatus = SyncStatus.synced;
  Timer? _cloudSyncDebounceTimer;

  String get _documentIdentifier =>
      widget.fileName ?? widget.pdfPath.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    _documentId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
    _loadPdfDocument();
    _loadAnnotationsOfflineFirst();
  }

  @override
  void dispose() {
    _cloudSyncDebounceTimer?.cancel();
    _transformationController.dispose();
    PdfViewerPlatform.instance.closeDocument(_documentId);
    super.dispose();
  }

  /// Converts raw RGBA pixel buffer into Flutter's native ui.Image
  Future<ui.Image> _createUiImage(Uint8List pixels, int width, int height) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image image) {
        completer.complete(image);
      },
    );
    return completer.future;
  }

  /// Initializes PDF Renderer and loads page dimensions
  Future<void> _loadPdfDocument() async {
    try {
      setState(() => _isLoadingPage = true);

      final platform = PdfViewerPlatform.instance;
      final pageCountResult =
          await platform.loadPdfFromFile(widget.pdfPath, _documentId);

      _pageCount = int.tryParse(pageCountResult ?? '1') ?? 1;

      final widths = await platform.getPagesWidth(_documentId);
      final heights = await platform.getPagesHeight(_documentId);

      if (widths != null && widths.isNotEmpty) {
        _pageWidth = (widths[0] as num).toDouble();
      }
      if (heights != null && heights.isNotEmpty) {
        _pageHeight = (heights[0] as num).toDouble();
      }

      await _renderCurrentPage();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingPage = false);
      debugPrint('Error loading PDF: $e');
    }
  }

  /// Renders the active PDF page to high-definition bitmap bytes
  Future<void> _renderCurrentPage() async {
    try {
      setState(() => _isLoadingPage = true);

      final platform = PdfViewerPlatform.instance;
      const int targetWidth = 1400;
      final int targetHeight = (_pageHeight > 0 && _pageWidth > 0)
          ? (1400 * _pageHeight / _pageWidth).toInt()
          : 1980;

      final bytes = await platform.getPage(
        _currentPage,
        targetWidth,
        targetHeight,
        _documentId,
      );

      if (!mounted) return;

      if (bytes != null) {
        final uiImage = await _createUiImage(bytes, targetWidth, targetHeight);
        if (!mounted) return;
        setState(() {
          _renderedPageUiImage = uiImage;
          _isDocumentLoaded = true;
          _isLoadingPage = false;
        });
      } else {
        setState(() => _isLoadingPage = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingPage = false);
      debugPrint('Error rendering page: $e');
    }
  }

  /// Changes the visible page
  Future<void> _goToPage(int page) async {
    if (page < 1 || page > _pageCount || page == _currentPage) return;
    setState(() {
      _currentPage = page;
    });
    await _renderCurrentPage();
  }

  /// Offline-first loading: Instantly loads from local storage, then syncs with Supabase in background
  Future<void> _loadAnnotationsOfflineFirst() async {
    // 1. INSTANT LOCAL LOAD (0ms latency, works offline)
    try {
      final localData =
          await DocumentStorageService.loadLocalAnnotations(_documentIdentifier);

      if (localData != null) {
        final List<dynamic>? strokesJson = localData['strokes'];
        final List<dynamic>? textsJson = localData['texts'];
        final List<dynamic>? imagesJson = localData['images'];

        if (mounted) {
          setState(() {
            _strokes.clear();
            if (strokesJson != null) {
              _strokes.addAll(strokesJson.map(
                  (e) => Stroke.fromJson(Map<String, dynamic>.from(e))));
            }

            _textAnnotations.clear();
            if (textsJson != null) {
              _textAnnotations.addAll(textsJson.map((e) =>
                  TextAnnotation.fromJson(Map<String, dynamic>.from(e))));
            }

            _imageAnnotations.clear();
            if (imagesJson != null) {
              _imageAnnotations.addAll(imagesJson.map((e) =>
                  ImageAnnotation.fromJson(Map<String, dynamic>.from(e))));
            }

            _syncStatus = SyncStatus.savedLocally;
          });
        }
      }
    } catch (e) {
      debugPrint('Local annotation load note: $e');
    }

    // 2. BACKGROUND CLOUD SYNC FROM SUPABASE
    try {
      final client = Supabase.instance.client;
      final response = await client
          .from('document_annotations')
          .select()
          .eq('document_name', _documentIdentifier)
          .maybeSingle();

      if (!mounted) return;

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

        // Update if cloud has data and local was empty or we're online
        if (loadedStrokes.isNotEmpty ||
            loadedTexts.isNotEmpty ||
            loadedImages.isNotEmpty ||
            _strokes.isEmpty) {
          setState(() {
            _strokes.clear();
            _strokes.addAll(loadedStrokes);

            _textAnnotations.clear();
            _textAnnotations.addAll(loadedTexts);

            _imageAnnotations.clear();
            _imageAnnotations.addAll(loadedImages);

            _syncStatus = SyncStatus.synced;
          });

          // Keep local cache fresh
          await DocumentStorageService.saveLocalAnnotations(
            _documentIdentifier,
            strokes: _strokes,
            texts: _textAnnotations,
            images: _imageAnnotations,
          );
        }
      } else {
        // If nothing in cloud yet, mark as synced or saved locally
        setState(() => _syncStatus = SyncStatus.synced);
      }
    } catch (_) {
      // Offline mode: keep local data seamlessly
      if (mounted) {
        setState(() => _syncStatus = SyncStatus.offline);
      }
    }
  }

  /// Automatically saves annotations to local storage immediately and debounces cloud sync
  void _autoSaveAndSync() {
    final totalItems =
        _strokes.length + _textAnnotations.length + _imageAnnotations.length;

    // 1. INSTANT LOCAL STORAGE SAVE (Works 100% Offline)
    DocumentStorageService.saveLocalAnnotations(
      _documentIdentifier,
      strokes: _strokes,
      texts: _textAnnotations,
      images: _imageAnnotations,
    );

    DocumentStorageService.saveOrUpdateDocument(
      DocumentItem(
        fileName: _documentIdentifier,
        filePath: widget.pdfPath,
        lastOpenedAt: DateTime.now(),
        annotationsCount: totalItems,
        isCloudSynced: _syncStatus == SyncStatus.synced,
      ),
    );

    setState(() => _syncStatus = SyncStatus.syncing);

    // 2. DEBOUNCED CLOUD SYNC TO SUPABASE (1.2s debounce)
    _cloudSyncDebounceTimer?.cancel();
    _cloudSyncDebounceTimer = Timer(const Duration(milliseconds: 1200), () async {
      await _syncToSupabaseDirect();
    });
  }

  /// Direct network sync to Supabase with graceful offline handling
  Future<void> _syncToSupabaseDirect() async {
    try {
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
      setState(() => _syncStatus = SyncStatus.synced);
    } catch (_) {
      // Offline fallback: data is securely saved in local storage!
      if (!mounted) return;
      setState(() => _syncStatus = SyncStatus.offline);
    }
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
    final recognizedText = await HandwritingCanvasDialog.show(context);

    if (!mounted) return;

    if (recognizedText != null && recognizedText.trim().isNotEmpty) {
      final screenSize = MediaQuery.of(context).size;
      setState(() {
        _textAnnotations.add(
          TextAnnotation(
            text: recognizedText.trim(),
            position: Offset(screenSize.width * 0.15, screenSize.height * 0.35),
            fontSize: 16.0,
            color: _selectedColor == AppTheme.highlighterColors[0]
                ? AppTheme.textPrimary
                : _selectedColor,
          ),
        );
        _activeTool = AnnotationTool.none;
      });

      _autoSaveAndSync();

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
      final XFile? image =
          await _imagePicker.pickImage(source: ImageSource.gallery);

      if (!mounted) return;

      if (image != null) {
        final screenSize = MediaQuery.of(context).size;
        setState(() {
          _imageAnnotations.add(
            ImageAnnotation(
              imagePath: image.path,
              position:
                  Offset(screenSize.width / 2 - 80, screenSize.height / 2 - 80),
              size: const Size(160, 160),
            ),
          );
          _activeTool = AnnotationTool.none;
        });

        _autoSaveAndSync();
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
      _autoSaveAndSync();
    }
  }

  /// Redoes the last undone stroke
  void _redo() {
    if (_redoHistory.isNotEmpty) {
      setState(() {
        final restored = _redoHistory.removeLast();
        _strokes.add(restored);
      });
      _autoSaveAndSync();
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
              _autoSaveAndSync();
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
    _autoSaveAndSync();
  }

  /// Deletes a specific digital text note
  void _deleteTextAnnotation(String id) {
    setState(() {
      _textAnnotations.removeWhere((txt) => txt.id == id);
      _selectedTextId = null;
    });
    _autoSaveAndSync();
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
                _autoSaveAndSync();
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

    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            // ==========================================
            // INTEGRATED HD PDF CANVAS & INTERACTIVE VIEWER
            // (PDF and Annotations share the EXACT same GPU container)
            // ==========================================
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final screenW = constraints.maxWidth;
                  final screenH = constraints.maxHeight;

                  final double pageAspect =
                      (_pageWidth > 0 && _pageHeight > 0)
                          ? _pageWidth / _pageHeight
                          : (595.0 / 842.0);

                  double displayW = screenW;
                  double displayH = screenW / pageAspect;

                  // If height is smaller than available viewport, fit nicely
                  if (displayH > screenH * 0.95 && screenH > 200) {
                    displayH = screenH * 0.95;
                    displayW = displayH * pageAspect;
                  }

                  return InteractiveViewer(
                    transformationController: _transformationController,
                    minScale: 1.0,
                    maxScale: 6.0,
                    panEnabled: _activeTool == AnnotationTool.none,
                    scaleEnabled: _activeTool == AnnotationTool.none,
                    clipBehavior: Clip.hardEdge,
                    child: Center(
                      child: Container(
                        width: displayW,
                        height: displayH,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF1E1B4B)
                                  .withValues(alpha: 0.14),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // 1. HD Rendered PDF Page Image
                            if (_renderedPageUiImage != null)
                              RawImage(
                                image: _renderedPageUiImage!,
                                width: displayW,
                                height: displayH,
                                fit: BoxFit.fill,
                              )
                            else
                              const Center(
                                child: CircularProgressIndicator(
                                  color: AppTheme.primaryPurple,
                                ),
                              ),

                            // 2. Annotation & Drawing Canvas
                            Positioned.fill(
                              child: IgnorePointer(
                                ignoring: _activeTool == AnnotationTool.none,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onPanStart: (DragStartDetails details) {
                                    if (_activeTool ==
                                            AnnotationTool.highlighter ||
                                        _activeTool ==
                                            AnnotationTool.straightLine) {
                                      setState(() {
                                        _redoHistory.clear();
                                        _currentStroke = Stroke(
                                          points: [details.localPosition],
                                          color: _selectedColor,
                                          strokeWidth: _strokeWidth,
                                          isStraightLine: _activeTool ==
                                              AnnotationTool.straightLine,
                                        );
                                      });
                                    }
                                  },
                                  onPanUpdate: (DragUpdateDetails details) {
                                    if (_currentStroke != null) {
                                      setState(() {
                                        _currentStroke!.points
                                            .add(details.localPosition);
                                      });
                                    }
                                  },
                                  onPanEnd: (DragEndDetails details) {
                                    if (_currentStroke != null) {
                                      setState(() {
                                        _strokes.add(_currentStroke!);
                                        _currentStroke = null;
                                      });
                                      _autoSaveAndSync();
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
                                    ),
                                    size: Size.infinite,
                                  ),
                                ),
                              ),
                            ),

                            // 3. Image Stickers (Photos)
                            ..._imageAnnotations.map((annotation) {
                              return Positioned(
                                left: annotation.position.dx,
                                top: annotation.position.dy,
                                child: _buildDraggableResizableImageWidget(
                                    annotation),
                              );
                            }),

                            // 4. Digital Text Notes (Handwriting)
                            ..._textAnnotations.map((annotation) {
                              return Positioned(
                                left: annotation.position.dx,
                                top: annotation.position.dy,
                                child: _buildDraggableTextWidget(annotation),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // Rendering Page Progress Shimmer
            if (_isLoadingPage)
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.primaryPurple,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Rendering page $_currentPage of $_pageCount...',
                          style: const TextStyle(
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
            // TOP BAR: Navigation, Document Title & Auto-Sync Status
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

  /// Draggable & Resizable Image Sticker Widget locked to PDF
  Widget _buildDraggableResizableImageWidget(ImageAnnotation annotation) {
    final isSelected = _selectedImageId == annotation.id;

    return GestureDetector(
      onPanUpdate: (DragUpdateDetails details) {
        setState(() {
          annotation.position += details.delta;
          _selectedImageId = annotation.id;
          _selectedTextId = null;
        });
      },
      onPanEnd: (_) => _autoSaveAndSync(),
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
            duration: const Duration(milliseconds: 80),
            width: annotation.size.width.clamp(30.0, 1200.0),
            height: annotation.size.height.clamp(30.0, 1200.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
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
              borderRadius: BorderRadius.circular(14),
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
                    final newWidth = (annotation.size.width + details.delta.dx)
                        .clamp(40.0, 800.0);
                    final newHeight = (annotation.size.height + details.delta.dy)
                        .clamp(40.0, 800.0);
                    annotation.size = Size(newWidth, newHeight);
                  });
                },
                onPanEnd: (_) => _autoSaveAndSync(),
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

  /// Draggable Digital Text Note Widget locked to PDF
  Widget _buildDraggableTextWidget(TextAnnotation annotation) {
    final isSelected = _selectedTextId == annotation.id;

    return GestureDetector(
      onPanUpdate: (DragUpdateDetails details) {
        setState(() {
          annotation.position += details.delta;
          _selectedTextId = annotation.id;
          _selectedImageId = null;
        });
      },
      onPanEnd: (_) => _autoSaveAndSync(),
      onTap: () {
        setState(() {
          _selectedTextId = isSelected ? null : annotation.id;
          _selectedImageId = null;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(14),
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
                fontSize: annotation.fontSize.clamp(8.0, 60.0),
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

  /// Elegant glassmorphic Top App Bar with Auto-Sync Status & Page Navigation
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
                          // Page Switcher Controls
                          if (_pageCount > 1)
                            GestureDetector(
                              onTap: _currentPage > 1
                                  ? () => _goToPage(_currentPage - 1)
                                  : null,
                              child: Icon(
                                CupertinoIcons.chevron_left_square,
                                size: 16,
                                color: _currentPage > 1
                                    ? AppTheme.primaryPurple
                                    : AppTheme.textMuted.withValues(alpha: 0.3),
                              ),
                            ),
                          if (_pageCount > 1) const SizedBox(width: 4),
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
                          if (_pageCount > 1) const SizedBox(width: 4),
                          if (_pageCount > 1)
                            GestureDetector(
                              onTap: _currentPage < _pageCount
                                  ? () => _goToPage(_currentPage + 1)
                                  : null,
                              child: Icon(
                                CupertinoIcons.chevron_right_square,
                                size: 16,
                                color: _currentPage < _pageCount
                                    ? AppTheme.primaryPurple
                                    : AppTheme.textMuted.withValues(alpha: 0.3),
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

              // Smart Auto-Sync Status Badge / Manual Sync Trigger
              _buildSyncStatusBadge(),
            ],
          ),
        ),
      ),
    );
  }

  /// Interactive Auto-Sync Badge showing real-time Cloud / Local status
  Widget _buildSyncStatusBadge() {
    Widget icon;
    String label;
    Color bgColor;
    Color textColor;

    switch (_syncStatus) {
      case SyncStatus.synced:
        icon = const Icon(CupertinoIcons.cloud_upload_fill,
            color: Color(0xFF10B981), size: 14);
        label = 'Synced';
        bgColor = const Color(0xFFECFDF5);
        textColor = const Color(0xFF065F46);
        break;
      case SyncStatus.syncing:
        icon = const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppTheme.primaryPurple,
          ),
        );
        label = 'Syncing...';
        bgColor = AppTheme.primaryPurpleLight;
        textColor = AppTheme.primaryPurpleDark;
        break;
      case SyncStatus.savedLocally:
        icon = const Icon(CupertinoIcons.checkmark_circle,
            color: AppTheme.primaryPurple, size: 14);
        label = 'Saved';
        bgColor = AppTheme.primaryPurpleLight;
        textColor = AppTheme.primaryPurpleDark;
        break;
      case SyncStatus.offline:
        icon = const Icon(CupertinoIcons.bolt_fill,
            color: Color(0xFFF59E0B), size: 14);
        label = 'Offline';
        bgColor = const Color(0xFFFFFBEB);
        textColor = const Color(0xFFB45309);
        break;
    }

    return Container(
      margin: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: textColor.withValues(alpha: 0.2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            _autoSaveAndSync();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_syncStatus == SyncStatus.offline
                    ? 'Saved locally (Offline mode ⚡)'
                    : 'Synced to Supabase Cloud ✨'),
                duration: const Duration(seconds: 1),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
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
                width: _activeTool == AnnotationTool.straightLine ? 3.0 : 10.0,
              ),
              _buildStrokeSizePreset(
                label: 'M',
                width: _activeTool == AnnotationTool.straightLine ? 5.0 : 16.0,
              ),
              _buildStrokeSizePreset(
                label: 'L',
                width: _activeTool == AnnotationTool.straightLine ? 8.0 : 24.0,
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
class BaseAnnotationPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final AnnotationTool activeTool;

  BaseAnnotationPainter({
    required this.strokes,
    required this.currentStroke,
    required this.activeTool,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw all committed historical strokes
    for (final stroke in strokes) {
      _renderStroke(canvas, stroke);
    }

    // 2. Draw currently active drag stroke (with live preview)
    if (currentStroke != null) {
      _renderStroke(canvas, currentStroke!);
    }
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
        canvas.drawLine(
          stroke.points.first,
          stroke.points.last,
          paint,
        );
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
        final start = stroke.points[0];
        path.moveTo(start.dx, start.dy);

        for (int i = 1; i < stroke.points.length - 1; i++) {
          final p0 = stroke.points[i];
          final p1 = stroke.points[i + 1];
          final midX = (p0.dx + p1.dx) / 2;
          final midY = (p0.dy + p1.dy) / 2;
          path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
        }

        if (stroke.points.length > 1) {
          final last = stroke.points.last;
          path.lineTo(last.dx, last.dy);
        }

        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BaseAnnotationPainter oldDelegate) {
    return true;
  }
}
