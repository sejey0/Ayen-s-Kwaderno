import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_pdfviewer_platform_interface/pdfviewer_platform_interface.dart';
import '../models/document_item_model.dart';
import '../models/image_annotation_model.dart';
import '../models/stroke_model.dart';
import '../models/text_annotation_model.dart';
import '../services/document_storage_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import '../widgets/image_cropper_dialog.dart';
import '../widgets/image_bg_remover_dialog.dart';

/// Supported annotation tool types in document editor
enum AnnotationTool {
  none, // Pan & Zoom Navigation Mode
  highlighter, // Semi-transparent highlighter drawing
  straightLine, // Auto-straightened coordinate lines
  eraser, // Interactive stroke eraser
  addImage, // Draggable/resizable image overlay
}

/// Drawing Pen / Marker Sub-Tool modes
enum PenSubTool {
  ballpen, // Opaque fine pen drawing
  highlighter, // Translucent marker highlighting
}

/// Eraser operating modes
enum EraserMode {
  drawErase, // Precision point-by-point drawing eraser
  wipeStroke, // Wipes entire stroke on contact
}

/// PDF Page Slide & Scroll Navigation Orientation
enum PageSlideOrientation {
  horizontal, // Slide left & right with side-by-side arrows (Default)
  vertical, // Scroll up & down with top & bottom arrows
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
    with TickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();
  final ImagePicker _imagePicker = ImagePicker();

  late final AnimationController _zoomAnimationController;
  Animation<Matrix4>? _zoomAnimation;

  // Active annotation tool state
  AnnotationTool _activeTool = AnnotationTool.none;
  PenSubTool _penSubTool = PenSubTool.highlighter;
  Color _selectedColor = AppTheme.highlighterColors[0];
  Color? _customColor;
  double _ballpenWidth = 3.0;
  double _highlighterWidth = 16.0;
  AnnotationTool _previousDrawingTool = AnnotationTool.highlighter;

  // Slide Orientation State (Default: Vertical)
  PageSlideOrientation _slideOrientation = PageSlideOrientation.vertical;
  bool _isHeaderVisible = true;
  bool _isToolbarVisible = true;

  // Per-Page Annotation Storage Maps
  final Map<int, List<Stroke>> _perPageStrokes = {};
  final Map<int, List<TextAnnotation>> _perPageTextAnnotations = {};
  final Map<int, List<ImageAnnotation>> _perPageImageAnnotations = {};

  // Active Page Drawing strokes state & Undo/Redo Snapshots
  final List<Stroke> _strokes = [];
  final List<List<Stroke>> _undoStack = [];
  final List<List<Stroke>> _redoStack = [];
  Stroke? _currentStroke;
  Offset? _currentEraserPos;
  EraserMode _eraserMode = EraserMode.drawErase;
  bool _isEraserMenuExpanded = true;
  bool _isThicknessMenuExpanded = true;

  // Digital Text Annotations state (Saved notes)
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
  double _displayPageWidth = 595.0;
  double _displayPageHeight = 842.0;
  bool _isCurrentlyZoomed = false;
  Offset? _swipeStartPos;
  int _activePointerCount = 0;
  bool _hadMultiTouch = false;
  bool _isDraggingAnnotation = false;
  ui.Image? _renderedPageUiImage;
  final Map<int, ui.Image> _renderedPages = {};
  late PageController _pageController;
  late final ScrollController _scrollController;
  bool _isLoadingPage = false;

  // Auto-Save & Synchronization State
  SyncStatus _syncStatus = SyncStatus.synced;
  Timer? _cloudSyncDebounceTimer;

  String get _documentIdentifier =>
      widget.fileName ?? widget.pdfPath.split(Platform.pathSeparator).last;

  bool get _isImageDocument {
    final lower = widget.pdfPath.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  @override
  void initState() {
    super.initState();
    _zoomAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() {
        if (_zoomAnimation != null) {
          _transformationController.value = _zoomAnimation!.value;
        }
      });
    _transformationController.addListener(() {
      final isZoomed =
          _transformationController.value.getMaxScaleOnAxis() > 1.05;
      if (isZoomed != _isCurrentlyZoomed && mounted) {
        setState(() {
          _isCurrentlyZoomed = isZoomed;
        });
      }
    });
    _pageController = PageController(initialPage: _currentPage - 1);
    _scrollController = ScrollController();
    _scrollController.addListener(() {
      final double totalItemH = _displayPageHeight + 16.0;
      if (totalItemH > 0) {
        final page = (_scrollController.offset / totalItemH).round() + 1;
        final clamped = page.clamp(1, _pageCount);
        if (clamped != _currentPage) {
          _onPageChanged(clamped);
        }
      }
    });
    _documentId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
    if (_isImageDocument) {
      _loadImageDocument();
    } else {
      _loadPdfDocument();
    }
    _loadAnnotationsOfflineFirst();
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _cloudSyncDebounceTimer?.cancel();
    _zoomAnimationController.dispose();
    _pageController.dispose();
    _scrollController.dispose();
    _transformationController.dispose();
    if (!_isImageDocument) {
      PdfViewerPlatform.instance.closeDocument(_documentId);
    }
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

  /// Loads standalone image file into the high-definition annotation canvas
  Future<void> _loadImageDocument() async {
    try {
      setState(() => _isLoadingPage = true);
      final file = File(widget.pdfPath);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      final uiImage = frameInfo.image;

      if (!mounted) return;
      setState(() {
        _renderedPageUiImage = uiImage;
        _renderedPages[1] = uiImage;
        _pageWidth = uiImage.width.toDouble();
        _pageHeight = uiImage.height.toDouble();
        _pageCount = 1;
        _currentPage = 1;
        _isLoadingPage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingPage = false);
      debugPrint('Error loading image document: $e');
    }
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

      await _preloadAdjacentPages(_currentPage);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingPage = false);
      debugPrint('Error loading PDF: $e');
    }
  }

  /// Renders a specific PDF page to high-definition bitmap bytes
  Future<void> _renderPage(int pageNum) async {
    if (pageNum < 1 || pageNum > _pageCount) return;
    if (_renderedPages.containsKey(pageNum)) return;

    try {
      final platform = PdfViewerPlatform.instance;
      const int targetWidth = 1400;
      final int targetHeight = (_pageHeight > 0 && _pageWidth > 0)
          ? (1400 * _pageHeight / _pageWidth).toInt()
          : 1980;

      final bytes = await platform.getPage(
        pageNum,
        targetWidth,
        targetHeight,
        _documentId,
      );

      if (!mounted || bytes == null) return;

      final uiImage = await _createUiImage(bytes, targetWidth, targetHeight);
      if (!mounted) return;

      setState(() {
        _renderedPages[pageNum] = uiImage;
        if (pageNum == _currentPage) {
          _renderedPageUiImage = uiImage;
          _isLoadingPage = false;
        }
      });
    } catch (e) {
      debugPrint('Error rendering page $pageNum: $e');
    }
  }

  /// Preloads the current page and adjacent pages for instantaneous drag response
  Future<void> _preloadAdjacentPages(int page) async {
    await _renderPage(page);
    if (page > 1) _renderPage(page - 1);
    if (page < _pageCount) _renderPage(page + 1);
  }

  /// Toggles device display orientation between Portrait and Landscape
  void _toggleScreenOrientation() {
    HapticFeedback.selectionClick();
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// Toggles between Vertical Scroll (Default) and Horizontal Slide
  void _toggleSlideOrientation() {
    HapticFeedback.selectionClick();
    setState(() {
      _slideOrientation = _slideOrientation == PageSlideOrientation.vertical
          ? PageSlideOrientation.horizontal
          : PageSlideOrientation.vertical;
      _pageController = PageController(initialPage: _currentPage - 1);
    });

    if (_slideOrientation == PageSlideOrientation.vertical) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final targetOffset =
              (_currentPage - 1) * (_displayPageHeight + 16.0);
          _scrollController.jumpTo(targetOffset);
        }
      });
    }
  }

  /// Handles drag-to-page event from PageView
  void _onPageChanged(int page) {
    if (page == _currentPage) return;

    // Save current active page annotations
    _perPageStrokes[_currentPage] = List.from(_strokes);
    _perPageTextAnnotations[_currentPage] = List.from(_textAnnotations);
    _perPageImageAnnotations[_currentPage] = List.from(_imageAnnotations);

    setState(() {
      _currentPage = page;
      _strokes.clear();
      _strokes.addAll(_perPageStrokes[page] ?? []);
      _textAnnotations.clear();
      _textAnnotations.addAll(_perPageTextAnnotations[page] ?? []);
      _imageAnnotations.clear();
      _imageAnnotations.addAll(_perPageImageAnnotations[page] ?? []);
      _undoStack.clear();
      _redoStack.clear();
      _currentStroke = null;
      _selectedTextId = null;
      _selectedImageId = null;
      _renderedPageUiImage = _renderedPages[page];
    });

    _preloadAdjacentPages(page);
  }

  /// Changes the visible page with smooth transition
  Future<void> _goToPage(int page) async {
    if (page < 1 || page > _pageCount) return;

    if (_transformationController.value != Matrix4.identity()) {
      _transformationController.value = Matrix4.identity();
    }

    HapticFeedback.selectionClick();

    if (_slideOrientation == PageSlideOrientation.vertical) {
      if (_scrollController.hasClients) {
        final targetOffset = (page - 1) * (_displayPageHeight + 16.0);
        _scrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      } else {
        _onPageChanged(page);
      }
    } else {
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          page - 1,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      } else {
        _onPageChanged(page);
      }
    }
  }

  /// Offline-first loading: Instantly loads from local storage, then syncs with Supabase in background
  Future<void> _loadAnnotationsOfflineFirst() async {
    // 1. INSTANT LOCAL LOAD (0ms latency, works offline)
    try {
      final localData =
          await DocumentStorageService.loadLocalAnnotations(_documentIdentifier);

      if (localData != null) {
        final Map<dynamic, dynamic>? strokesByPage =
            localData['strokes_by_page'];
        final Map<dynamic, dynamic>? textsByPage = localData['texts_by_page'];
        final Map<dynamic, dynamic>? imagesByPage =
            localData['images_by_page'];

        if (strokesByPage != null) {
          _perPageStrokes.clear();
          strokesByPage.forEach((k, v) {
            final pageNum = int.tryParse(k.toString()) ?? 1;
            _perPageStrokes[pageNum] = (v as List<dynamic>)
                .map((e) => Stroke.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          });
        }
        if (textsByPage != null) {
          _perPageTextAnnotations.clear();
          textsByPage.forEach((k, v) {
            final pageNum = int.tryParse(k.toString()) ?? 1;
            _perPageTextAnnotations[pageNum] = (v as List<dynamic>)
                .map((e) =>
                    TextAnnotation.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          });
        }
        if (imagesByPage != null) {
          _perPageImageAnnotations.clear();
          imagesByPage.forEach((k, v) {
            final pageNum = int.tryParse(k.toString()) ?? 1;
            _perPageImageAnnotations[pageNum] = (v as List<dynamic>)
                .map((e) =>
                    ImageAnnotation.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          });
        }

        final List<dynamic>? strokesJson = localData['strokes'];
        final List<dynamic>? textsJson = localData['texts'];
        final List<dynamic>? imagesJson = localData['images'];

        if (mounted) {
          setState(() {
            _strokes.clear();
            if (_perPageStrokes.containsKey(_currentPage)) {
              _strokes.addAll(_perPageStrokes[_currentPage]!);
            } else if (strokesJson != null && _currentPage == 1) {
              _strokes.addAll(strokesJson.map(
                  (e) => Stroke.fromJson(Map<String, dynamic>.from(e))));
              _perPageStrokes[1] = List.from(_strokes);
            }

            _textAnnotations.clear();
            if (_perPageTextAnnotations.containsKey(_currentPage)) {
              _textAnnotations.addAll(_perPageTextAnnotations[_currentPage]!);
            } else if (textsJson != null && _currentPage == 1) {
              _textAnnotations.addAll(textsJson.map((e) =>
                  TextAnnotation.fromJson(Map<String, dynamic>.from(e))));
              _perPageTextAnnotations[1] = List.from(_textAnnotations);
            }

            _imageAnnotations.clear();
            if (_perPageImageAnnotations.containsKey(_currentPage)) {
              _imageAnnotations.addAll(_perPageImageAnnotations[_currentPage]!);
            } else if (imagesJson != null && _currentPage == 1) {
              _imageAnnotations.addAll(imagesJson.map((e) =>
                  ImageAnnotation.fromJson(Map<String, dynamic>.from(e))));
              _perPageImageAnnotations[1] = List.from(_imageAnnotations);
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
      final activeUserId = UserService.instance.activeUserId;

      final scopedDocName = 'u_${activeUserId}___$_documentIdentifier';
      dynamic response;
      try {
        response = await client
            .from('document_annotations')
            .select()
            .eq('document_name', scopedDocName)
            .maybeSingle();
      } catch (_) {}

      if (response == null) {
        try {
          response = await client
              .from('document_annotations')
              .select()
              .eq('document_name', _documentIdentifier)
              .maybeSingle();
        } catch (_) {}
      }

      if (!mounted) return;

      if (response != null && response is Map) {
        final Map<dynamic, dynamic>? strokesByPage =
            response['strokes_data'] is Map ? response['strokes_data'] : null;
        final Map<dynamic, dynamic>? textsByPage =
            response['texts_data'] is Map ? response['texts_data'] : null;
        final Map<dynamic, dynamic>? imagesByPage =
            response['images_data'] is Map ? response['images_data'] : null;

        if (strokesByPage != null) {
          _perPageStrokes.clear();
          strokesByPage.forEach((k, v) {
            final pageNum = int.tryParse(k.toString()) ?? 1;
            _perPageStrokes[pageNum] = (v as List<dynamic>)
                .map((e) => Stroke.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          });
        }
        if (textsByPage != null) {
          _perPageTextAnnotations.clear();
          textsByPage.forEach((k, v) {
            final pageNum = int.tryParse(k.toString()) ?? 1;
            _perPageTextAnnotations[pageNum] = (v as List<dynamic>)
                .map((e) =>
                    TextAnnotation.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          });
        }
        if (imagesByPage != null) {
          _perPageImageAnnotations.clear();
          imagesByPage.forEach((k, v) {
            final pageNum = int.tryParse(k.toString()) ?? 1;
            _perPageImageAnnotations[pageNum] = (v as List<dynamic>)
                .map((e) =>
                    ImageAnnotation.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          });
        }

        final List<dynamic>? strokesJson =
            response['strokes_data'] is List ? response['strokes_data'] : null;
        final List<dynamic>? textsJson =
            response['texts_data'] is List ? response['texts_data'] : null;
        final List<dynamic>? imagesJson =
            response['images_data'] is List ? response['images_data'] : null;

        final loadedStrokes = <Stroke>[];
        final loadedTexts = <TextAnnotation>[];
        final loadedImages = <ImageAnnotation>[];

        if (_perPageStrokes.containsKey(_currentPage)) {
          loadedStrokes.addAll(_perPageStrokes[_currentPage]!);
        } else if (strokesJson != null && _currentPage == 1) {
          loadedStrokes.addAll(strokesJson
              .map((e) => Stroke.fromJson(Map<String, dynamic>.from(e))));
          _perPageStrokes[1] = List.from(loadedStrokes);
        }

        if (_perPageTextAnnotations.containsKey(_currentPage)) {
          loadedTexts.addAll(_perPageTextAnnotations[_currentPage]!);
        } else if (textsJson != null && _currentPage == 1) {
          loadedTexts.addAll(textsJson.map(
              (e) => TextAnnotation.fromJson(Map<String, dynamic>.from(e))));
          _perPageTextAnnotations[1] = List.from(loadedTexts);
        }

        if (_perPageImageAnnotations.containsKey(_currentPage)) {
          loadedImages.addAll(_perPageImageAnnotations[_currentPage]!);
        } else if (imagesJson != null && _currentPage == 1) {
          loadedImages.addAll(imagesJson.map(
              (e) => ImageAnnotation.fromJson(Map<String, dynamic>.from(e))));
          _perPageImageAnnotations[1] = List.from(loadedImages);
        }

        if (loadedStrokes.isNotEmpty ||
            loadedTexts.isNotEmpty ||
            loadedImages.isNotEmpty ||
            (_strokes.isEmpty && _textAnnotations.isEmpty && _imageAnnotations.isEmpty)) {
          setState(() {
            _strokes.clear();
            _strokes.addAll(loadedStrokes);
            _textAnnotations.clear();
            _textAnnotations.addAll(loadedTexts);
            _imageAnnotations.clear();
            _imageAnnotations.addAll(loadedImages);
            _syncStatus = SyncStatus.synced;
          });
        }

        // Keep local cache fresh
        await DocumentStorageService.saveLocalAnnotations(
          _documentIdentifier,
          strokes: _strokes,
          texts: _textAnnotations,
          images: _imageAnnotations,
          extraData: {
            'page_count': _pageCount,
            'strokes_by_page': {
              for (var entry in _perPageStrokes.entries)
                entry.key.toString():
                    entry.value.map((s) => s.toJson()).toList(),
            },
            'texts_by_page': {
              for (var entry in _perPageTextAnnotations.entries)
                entry.key.toString():
                    entry.value.map((t) => t.toJson()).toList(),
            },
            'images_by_page': {
              for (var entry in _perPageImageAnnotations.entries)
                entry.key.toString():
                    entry.value.map((i) => i.toJson()).toList(),
            },
          },
        );
      } else {
        setState(() => _syncStatus = SyncStatus.synced);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _syncStatus = SyncStatus.offline);
      }
    }
  }

  /// Automatically saves annotations to local storage immediately and debounces cloud sync
  void _autoSaveAndSync() {
    _perPageStrokes[_currentPage] = List.from(_strokes);
    _perPageTextAnnotations[_currentPage] = List.from(_textAnnotations);
    _perPageImageAnnotations[_currentPage] = List.from(_imageAnnotations);

    int totalItems = 0;
    for (final list in _perPageStrokes.values) {
      totalItems += list.length;
    }
    for (final list in _perPageTextAnnotations.values) {
      totalItems += list.length;
    }
    for (final list in _perPageImageAnnotations.values) {
      totalItems += list.length;
    }

    // 1. INSTANT LOCAL STORAGE SAVE (Works 100% Offline)
    DocumentStorageService.saveLocalAnnotations(
      _documentIdentifier,
      strokes: _strokes,
      texts: _textAnnotations,
      images: _imageAnnotations,
      extraData: {
        'page_count': _pageCount,
        'strokes_by_page': {
          for (var entry in _perPageStrokes.entries)
            entry.key.toString(): entry.value.map((s) => s.toJson()).toList(),
        },
        'texts_by_page': {
          for (var entry in _perPageTextAnnotations.entries)
            entry.key.toString(): entry.value.map((t) => t.toJson()).toList(),
        },
        'images_by_page': {
          for (var entry in _perPageImageAnnotations.entries)
            entry.key.toString(): entry.value.map((i) => i.toJson()).toList(),
        },
      },
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
    _cloudSyncDebounceTimer =
        Timer(const Duration(milliseconds: 1200), () async {
      await _syncToSupabaseDirect();
    });
  }

  /// Direct network sync to Supabase with graceful offline handling
  Future<void> _syncToSupabaseDirect() async {
    try {
      final client = Supabase.instance.client;
      final activeUserId = UserService.instance.activeUserId;
      final payload = {
        'document_name': 'u_${activeUserId}___$_documentIdentifier',
        'strokes_data': {
          for (var entry in _perPageStrokes.entries)
            entry.key.toString(): entry.value.map((s) => s.toJson()).toList(),
        },
        'texts_data': {
          for (var entry in _perPageTextAnnotations.entries)
            entry.key.toString(): entry.value.map((t) => t.toJson()).toList(),
        },
        'images_data': {
          for (var entry in _perPageImageAnnotations.entries)
            entry.key.toString(): entry.value.map((i) => i.toJson()).toList(),
        },
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      await client
          .from('document_annotations')
          .upsert(payload, onConflict: 'document_name');

      int totalItems = 0;
      for (final list in _perPageStrokes.values) {
        totalItems += list.length;
      }
      for (final list in _perPageTextAnnotations.values) {
        totalItems += list.length;
      }
      for (final list in _perPageImageAnnotations.values) {
        totalItems += list.length;
      }

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
      if (!mounted) return;
      setState(() => _syncStatus = SyncStatus.offline);
    }
  }

  /// Smoothly animates zoom level between 1.0x (overview) and 2.2x (reading zoom)
  void _toggleZoom([Offset? focalPoint]) {
    final currentMatrix = _transformationController.value;
    final currentScale = currentMatrix.getMaxScaleOnAxis();

    final targetScale = currentScale > 1.3 ? 1.0 : 2.2;
    Matrix4 targetMatrix;

    if (targetScale == 1.0) {
      targetMatrix = Matrix4.identity();
    } else {
      final pos = focalPoint ??
          Offset(_displayPageWidth / 2, _displayPageHeight / 2);
      final tx = -pos.dx * (targetScale - 1);
      final ty = -pos.dy * (targetScale - 1);
      targetMatrix = Matrix4.identity()
        ..storage[0] = targetScale
        ..storage[5] = targetScale
        ..storage[12] = tx
        ..storage[13] = ty;
    }

    _zoomAnimation = Matrix4Tween(
      begin: currentMatrix,
      end: targetMatrix,
    ).animate(CurvedAnimation(
      parent: _zoomAnimationController,
      curve: Curves.easeOutCubic,
    ));

    HapticFeedback.selectionClick();
    _zoomAnimationController.forward(from: 0.0);
  }

  /// Changes the active annotation tool mode
  void _onToolSelected(AnnotationTool tool) {
    if (tool == AnnotationTool.none && _activeTool == AnnotationTool.none) {
      // Tapping Navigate button while already active smoothly toggles reading zoom / fit overview
      _toggleZoom();
      return;
    }

    if (_activeTool == AnnotationTool.eraser &&
        (tool == AnnotationTool.highlighter ||
            tool == AnnotationTool.straightLine)) {
      setState(() {
        _activeTool = tool;
        _previousDrawingTool = tool;
        _isThicknessMenuExpanded = true;
      });
      return;
    }

    if (tool == _activeTool) {
      setState(() => _activeTool = AnnotationTool.none);
      return;
    }

    setState(() {
      _activeTool = tool;
      if (tool == AnnotationTool.highlighter ||
          tool == AnnotationTool.straightLine) {
        _previousDrawingTool = tool;
      }
      _selectedImageId = null;
      _selectedTextId = null;
    });

    if (tool == AnnotationTool.addImage) {
      _pickAndInsertImage();
    }
  }

  /// Opens gallery to insert a sticker / photo onto the PDF
  Future<void> _pickAndInsertImage() async {
    try {
      final XFile? image =
          await _imagePicker.pickImage(source: ImageSource.gallery);

      if (!mounted) return;

      if (image != null) {
        final newAnnotation = ImageAnnotation(
          imagePath: image.path,
          position: const Offset(40, 80),
          size: const Size(180, 180),
        );
        setState(() {
          _imageAnnotations.add(newAnnotation);
          _perPageImageAnnotations[_currentPage] = List.from(_imageAnnotations);
          _selectedImageId = newAnnotation.id;
          _selectedTextId = null;
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

  /// Records a snapshot of the current strokes for full Undo/Redo capability
  void _recordUndoSnapshot() {
    _undoStack.add(_strokes.map((s) => s.copyWith()).toList());
    if (_undoStack.length > 50) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Dense interpolation of points along a sequence of vertices (every ~3.0px) for ultra-fine precision erasing
  static List<Offset> _densifyPoints(List<Offset> points, {double step = 3.0}) {
    if (points.length < 2) return List.from(points);
    final List<Offset> dense = [points.first];

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final dist = (p1 - p0).distance;
      if (dist > step) {
        final int count = (dist / step).ceil();
        for (int s = 1; s < count; s++) {
          final t = s / count;
          dense.add(Offset(
            p0.dx + (p1.dx - p0.dx) * t,
            p0.dy + (p1.dy - p0.dy) * t,
          ));
        }
      }
      dense.add(p1);
    }
    return dense;
  }

  /// Undoes the last stroke or eraser action
  void _undo() {
    if (_undoStack.isNotEmpty) {
      setState(() {
        _redoStack.add(_strokes.map((s) => s.copyWith()).toList());
        final previous = _undoStack.removeLast();
        _strokes.clear();
        _strokes.addAll(previous.map((s) => s.copyWith()));
        _perPageStrokes[_currentPage] = List.from(_strokes);
      });
      HapticFeedback.lightImpact();
      _autoSaveAndSync();
    } else if (_strokes.isNotEmpty) {
      setState(() {
        final removed = _strokes.removeLast();
        _redoStack.add([removed]);
        _perPageStrokes[_currentPage] = List.from(_strokes);
      });
      HapticFeedback.lightImpact();
      _autoSaveAndSync();
    }
  }

  /// Redoes the last undone action
  void _redo() {
    if (_redoStack.isNotEmpty) {
      setState(() {
        _undoStack.add(_strokes.map((s) => s.copyWith()).toList());
        final next = _redoStack.removeLast();
        _strokes.clear();
        _strokes.addAll(next.map((s) => s.copyWith()));
        _perPageStrokes[_currentPage] = List.from(_strokes);
      });
      HapticFeedback.lightImpact();
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
              _recordUndoSnapshot();
              setState(() {
                _strokes.clear();
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

  /// Erases strokes near eraserPos depending on the active _eraserMode
  void _eraseStrokesNear(Offset eraserPos, double radius) {
    if (_eraserMode == EraserMode.wipeStroke) {
      // Mode 1: Wipe Whole Stroke (deletes entire line on contact)
      bool removedAny = false;
      setState(() {
        _strokes.removeWhere((stroke) {
          final hit = stroke.points
              .any((p) => (p - eraserPos).distance <= radius + 4.0);
          if (hit) removedAny = true;
          return hit;
        });
        if (removedAny) {
          _perPageStrokes[_currentPage] = List.from(_strokes);
        }
      });
      if (removedAny) {
        HapticFeedback.mediumImpact();
        _autoSaveAndSync();
      }
    } else {
      // Mode 2: Precision Draw Erase (point-by-point path carving)
      bool modified = false;
      final List<Stroke> updatedStrokes = [];

      for (final stroke in _strokes) {
        if (stroke.points.isEmpty) continue;

        // Densify points along path to ensure high-resolution point-by-point erasing
        final points = stroke.points.length < 5
            ? _densifyPoints(stroke.points)
            : stroke.points;

        final List<List<Offset>> subSegments = [];
        List<Offset> currentSegment = [];

        for (final p in points) {
          final dist = (p - eraserPos).distance;
          if (dist > radius) {
            currentSegment.add(p);
          } else {
            // Point erased! End current segment
            if (currentSegment.isNotEmpty) {
              subSegments.add(List.from(currentSegment));
              currentSegment.clear();
            }
            modified = true;
          }
        }

        if (currentSegment.isNotEmpty) {
          subSegments.add(List.from(currentSegment));
        }

        // Re-add remaining sub-segments
        for (final seg in subSegments) {
          if (seg.isNotEmpty) {
            updatedStrokes.add(Stroke(
              points: seg,
              color: stroke.color,
              strokeWidth: stroke.strokeWidth,
              isStraightLine: stroke.isStraightLine,
            ));
          }
        }
      }

      if (modified) {
        setState(() {
          _strokes.clear();
          _strokes.addAll(updatedStrokes);
          _perPageStrokes[_currentPage] = List.from(_strokes);
        });
        _autoSaveAndSync();
      }
    }
  }

  /// Deletes a specific image sticker
  void _deleteImageAnnotation(String id) {
    setState(() {
      _imageAnnotations.removeWhere((img) => img.id == id);
      _perPageImageAnnotations[_currentPage]?.removeWhere((img) => img.id == id);
      for (final list in _perPageImageAnnotations.values) {
        list.removeWhere((img) => img.id == id);
      }
      _selectedImageId = null;
    });
    _autoSaveAndSync();
  }

  /// Opens the interactive In-App Image Cropper for an image sticker
  Future<void> _openImageCropper(ImageAnnotation annotation) async {
    final croppedPath =
        await ImageCropperDialog.show(context, annotation.imagePath);

    if (croppedPath != null && mounted) {
      try {
        final bytes = await File(croppedPath).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final img = frame.image;

        final newAspect = img.width / img.height;
        final currentWidth = annotation.size.width;

        setState(() {
          annotation.imagePath = croppedPath;
          annotation.size = Size(currentWidth, currentWidth / newAspect);
        });

        _autoSaveAndSync();
        HapticFeedback.mediumImpact();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.crop, size: 16, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Image cropped successfully'),
                ],
              ),
              backgroundColor: AppTheme.primaryPurple,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        setState(() {
          annotation.originalImagePath ??= annotation.imagePath;
          annotation.originalSize ??= annotation.size;
          annotation.imagePath = croppedPath;
        });
        _autoSaveAndSync();
      }
    }
  }

  /// Opens the interactive Gemini AI Background Remover Studio for an image sticker
  Future<void> _openImageBgRemover(ImageAnnotation annotation) async {
    // ALWAYS use the original source image so opening BG remover never compounds or degrades repetitively
    final sourcePath = annotation.originalImagePath ?? annotation.imagePath;
    final cleanPath =
        await ImageBackgroundRemoverDialog.show(context, sourcePath);

    if (cleanPath != null && mounted) {
      setState(() {
        annotation.originalImagePath ??= annotation.imagePath;
        annotation.originalSize ??= annotation.size;
        annotation.imagePath = cleanPath;
        annotation.border = 'none';
      });
      _autoSaveAndSync();
      HapticFeedback.mediumImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.sparkles, size: 16, color: Colors.white),
                SizedBox(width: 8),
                Text('Gemini AI background removed'),
              ],
            ),
            backgroundColor: AppTheme.primaryPurple,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Opens a modern styling sheet for Image Shape and Border styles
  void _openImageStylePicker(ImageAnnotation annotation) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                color: AppTheme.surfaceWhite,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1E1B4B).withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: const [
                          Icon(CupertinoIcons.paintbrush_fill,
                              size: 18, color: AppTheme.primaryPurple),
                          SizedBox(width: 8),
                          Text(
                            'Image Shape & Border',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(CupertinoIcons.xmark_circle_fill,
                            color: AppTheme.textMuted, size: 22),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Section 1: Shape Styles
                  const Text(
                    'Border Shape',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: [
                        _buildShapeOptionPill(
                          label: 'Rounded',
                          icon: CupertinoIcons.square_fill_line_vertical_square,
                          shapeKey: 'rounded',
                          currentShape: annotation.shape,
                          onSelect: () {
                            setState(() => annotation.shape = 'rounded');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildShapeOptionPill(
                          label: 'Sharp',
                          icon: CupertinoIcons.square,
                          shapeKey: 'rectangle',
                          currentShape: annotation.shape,
                          onSelect: () {
                            setState(() => annotation.shape = 'rectangle');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildShapeOptionPill(
                          label: 'Pill',
                          icon: CupertinoIcons.capsule,
                          shapeKey: 'pill',
                          currentShape: annotation.shape,
                          onSelect: () {
                            setState(() => annotation.shape = 'pill');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildShapeOptionPill(
                          label: 'Circle',
                          icon: CupertinoIcons.circle,
                          shapeKey: 'circle',
                          currentShape: annotation.shape,
                          onSelect: () {
                            setState(() => annotation.shape = 'circle');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildShapeOptionPill(
                          label: 'Polaroid',
                          icon: CupertinoIcons.photo,
                          shapeKey: 'polaroid',
                          currentShape: annotation.shape,
                          onSelect: () {
                            setState(() => annotation.shape = 'polaroid');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Section 2: Border Styles
                  const Text(
                    'Border Outline',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: [
                        _buildBorderOptionPill(
                          label: 'White',
                          color: Colors.white,
                          borderKey: 'white',
                          currentBorder: annotation.border,
                          onSelect: () {
                            setState(() => annotation.border = 'white');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildBorderOptionPill(
                          label: 'Purple',
                          color: AppTheme.primaryPurple,
                          borderKey: 'purple',
                          currentBorder: annotation.border,
                          onSelect: () {
                            setState(() => annotation.border = 'purple');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildBorderOptionPill(
                          label: 'Dark',
                          color: const Color(0xFF1E293B),
                          borderKey: 'dark',
                          currentBorder: annotation.border,
                          onSelect: () {
                            setState(() => annotation.border = 'dark');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildBorderOptionPill(
                          label: 'None',
                          color: Colors.transparent,
                          borderKey: 'none',
                          currentBorder: annotation.border,
                          onSelect: () {
                            setState(() => annotation.border = 'none');
                            setSheetState(() {});
                            _autoSaveAndSync();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildShapeOptionPill({
    required String label,
    required IconData icon,
    required String shapeKey,
    required String currentShape,
    required VoidCallback onSelect,
  }) {
    final isSelected = currentShape == shapeKey;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onSelect();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryPurple
              : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? AppTheme.accentPink
                : AppTheme.dividerColor,
            width: isSelected ? 1.5 : 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? Colors.white : AppTheme.textPrimary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: isSelected ? Colors.white : AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBorderOptionPill({
    required String label,
    required Color color,
    required String borderKey,
    required String currentBorder,
    required VoidCallback onSelect,
  }) {
    final isSelected = currentBorder == borderKey;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onSelect();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryPurple
              : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? AppTheme.accentPink
                : AppTheme.dividerColor,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: color == Colors.transparent ? Colors.transparent : color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.white : Colors.black26,
                  width: 1.5,
                ),
              ),
              child: color == Colors.transparent
                  ? const Icon(CupertinoIcons.slash_circle,
                      size: 10, color: AppTheme.textMuted)
                  : null,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: isSelected ? Colors.white : AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      color: AppTheme.primaryPurpleLight,
      child: const Center(
        child: Icon(
          Icons.broken_image_rounded,
          color: AppTheme.textMuted,
          size: 32,
        ),
      ),
    );
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

                  if (displayH > screenH * 0.90 && screenH > 200) {
                    displayH = screenH * 0.90;
                    displayW = displayH * pageAspect;
                  }

                  _displayPageWidth = displayW;
                  _displayPageHeight = displayH;

                  return InteractiveViewer(
                    transformationController: _transformationController,
                    minScale: 1.0,
                    maxScale: 6.0,
                    panEnabled: _activeTool == AnnotationTool.none,
                    scaleEnabled: _activeTool == AnnotationTool.none,
                    boundaryMargin: EdgeInsets.zero,
                    clipBehavior: Clip.hardEdge,
                    child: Center(
                      child: Listener(
                        onPointerDown: (PointerDownEvent event) {
                          _activePointerCount++;
                          if (_isDraggingAnnotation ||
                              _selectedImageId != null ||
                              _selectedTextId != null) {
                            _swipeStartPos = null;
                            return;
                          }
                          if (_activePointerCount == 1) {
                            _swipeStartPos = event.position;
                            _hadMultiTouch = false;
                          } else if (_activePointerCount > 1) {
                            _hadMultiTouch = true;
                          }
                        },
                        onPointerUp: (PointerUpEvent event) {
                          _activePointerCount =
                              (_activePointerCount - 1).clamp(0, 10);
                          if (_activePointerCount == 0 &&
                              !_hadMultiTouch &&
                              !_isCurrentlyZoomed &&
                              !_isDraggingAnnotation &&
                              _selectedImageId == null &&
                              _selectedTextId == null &&
                              _activeTool == AnnotationTool.none &&
                              _swipeStartPos != null) {
                            final double dx =
                                event.position.dx - _swipeStartPos!.dx;
                            final double dy =
                                event.position.dy - _swipeStartPos!.dy;

                            if (_slideOrientation ==
                                PageSlideOrientation.horizontal) {
                              if (dx < -45 && _currentPage < _pageCount) {
                                _goToPage(_currentPage + 1);
                              } else if (dx > 45 && _currentPage > 1) {
                                _goToPage(_currentPage - 1);
                              }
                            } else {
                              if (dy < -45 && _currentPage < _pageCount) {
                                _goToPage(_currentPage + 1);
                              } else if (dy > 45 && _currentPage > 1) {
                                _goToPage(_currentPage - 1);
                              }
                            }
                          }
                          if (_activePointerCount == 0) {
                            _swipeStartPos = null;
                            _hadMultiTouch = false;
                          }
                        },
                        onPointerCancel: (PointerCancelEvent event) {
                          _activePointerCount =
                              (_activePointerCount - 1).clamp(0, 10);
                          if (_activePointerCount == 0) {
                            _swipeStartPos = null;
                            _hadMultiTouch = false;
                          }
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTapDown: (details) {
                            if (_activeTool == AnnotationTool.none) {
                              _toggleZoom(details.localPosition);
                            }
                          },
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              final isVertical = _slideOrientation ==
                                  PageSlideOrientation.vertical;
                              return SlideTransition(
                                position: Tween<Offset>(
                                  begin: isVertical
                                      ? const Offset(0.0, 0.04)
                                      : const Offset(0.04, 0.0),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              );
                            },
                            child: KeyedSubtree(
                              key: ValueKey<int>(_currentPage),
                              child: _buildSinglePageView(
                                  _currentPage, displayW, displayH),
                            ),
                          ),
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
                top: MediaQuery.of(context).padding.top + 90,
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
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                offset: _isHeaderVisible ? Offset.zero : const Offset(0, -1.2),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _isHeaderVisible ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !_isHeaderVisible,
                    child: _buildTopAppBar(displayName, totalAnnotationsCount),
                  ),
                ),
              ),
            ),

            // Floating Mini Header Unhide Bubble (when header is collapsed)
            if (!_isHeaderVisible)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 14,
                child: _buildFloatingUnhideHeaderButton(),
              ),

            // ==========================================
            // FLOATING TOOLBAR: Bottom Annotation Bar
            // ==========================================
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                offset: _isToolbarVisible ? Offset.zero : const Offset(0, 1.3),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _isToolbarVisible ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !_isToolbarVisible,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 1. Floating Eraser Options Bubble (Floats on top of the icons)
                        if (_activeTool == AnnotationTool.eraser &&
                            _isEraserMenuExpanded) ...[
                          _buildFloatingEraserOptionsBubble(),
                          const SizedBox(height: 8),
                        ],

                        // 2. Floating Thickness Options Bubble (Floats on top of Highlighter/Pen icons)
                        if ((_activeTool == AnnotationTool.highlighter ||
                                _activeTool == AnnotationTool.straightLine) &&
                            _isThicknessMenuExpanded) ...[
                          _buildFloatingThicknessOptionsBubble(),
                          const SizedBox(height: 8),
                        ],

                        // 3. Secondary Color/Stroke Palette (with Ballpen, Highlighter, Eraser)
                        if (_activeTool == AnnotationTool.highlighter ||
                            _activeTool == AnnotationTool.straightLine ||
                            _activeTool == AnnotationTool.eraser)
                          _buildColorPickerSubBar(),

                        const SizedBox(height: 10),

                        // 4. Main Floating Annotation Toolbar
                        _buildFloatingBottomToolbar(),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Floating Mini Tools Unhide Pill (when bottom toolbar is collapsed)
            if (!_isToolbarVisible)
              Positioned(
                bottom: 24,
                right: 16,
                child: _buildFloatingUnhideToolbarButton(),
              ),
          ],
        ),
      ),
    );
  }

  /// Single Page Content View for PageView (renders page background + strokes + stickers + text notes)
  Widget _buildSinglePageView(int pageNum, double displayW, double displayH) {
    final isCurrent = pageNum == _currentPage;
    final uiImage = _renderedPages[pageNum] ??
        (isCurrent ? _renderedPageUiImage : null);

    final pageStrokes =
        isCurrent ? _strokes : (_perPageStrokes[pageNum] ?? []);
    final pageCurrentStroke = isCurrent ? _currentStroke : null;
    final pageImages =
        isCurrent ? _imageAnnotations : (_perPageImageAnnotations[pageNum] ?? []);
    final pageTexts =
        isCurrent ? _textAnnotations : (_perPageTextAnnotations[pageNum] ?? []);

    final double refW = (_pageWidth > 0) ? _pageWidth : 595.0;
    final double refH = (_pageHeight > 0) ? _pageHeight : 842.0;
    final double scaleX = displayW / refW;
    final double scaleY = displayH / refH;

    return Center(
      child: Container(
        width: displayW,
        height: displayH,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1E1B4B).withValues(alpha: 0.14),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. HD Rendered PDF Page Image
            if (uiImage != null)
              RawImage(
                image: uiImage,
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
              child: isCurrent
                  ? IgnorePointer(
                      ignoring: _activeTool == AnnotationTool.none,
                      child: MouseRegion(
                        cursor: _activeTool == AnnotationTool.highlighter ||
                                _activeTool == AnnotationTool.straightLine
                            ? SystemMouseCursors.precise
                            : (_activeTool == AnnotationTool.eraser
                                ? SystemMouseCursors.noDrop
                                : SystemMouseCursors.basic),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (DragStartDetails details) {
                            _recordUndoSnapshot();
                            final refPoint = Offset(
                              details.localPosition.dx / scaleX,
                              details.localPosition.dy / scaleY,
                            );

                            if (_activeTool == AnnotationTool.eraser) {
                              setState(() {
                                _currentEraserPos = refPoint;
                              });
                              _eraseStrokesNear(refPoint, 12.0);
                            } else if (_activeTool == AnnotationTool.highlighter ||
                                _activeTool == AnnotationTool.straightLine) {
                              final isPen = _penSubTool == PenSubTool.ballpen;
                              final activeWidth =
                                  isPen ? _ballpenWidth : _highlighterWidth;
                              setState(() {
                                _currentStroke = Stroke(
                                  points: [refPoint],
                                  color: isPen
                                      ? _selectedColor.withValues(alpha: 1.0)
                                      : _selectedColor,
                                  strokeWidth: activeWidth,
                                  isStraightLine:
                                      _activeTool == AnnotationTool.straightLine,
                                );
                              });
                            }
                          },
                          onPanUpdate: (DragUpdateDetails details) {
                            final refPoint = Offset(
                              details.localPosition.dx / scaleX,
                              details.localPosition.dy / scaleY,
                            );

                            if (_activeTool == AnnotationTool.eraser) {
                              setState(() {
                                _currentEraserPos = refPoint;
                              });
                              _eraseStrokesNear(refPoint, 12.0);
                            } else if (_currentStroke != null) {
                              setState(() {
                                _currentStroke!.points.add(refPoint);
                              });
                            }
                          },
                          onPanEnd: (DragEndDetails details) {
                            if (_activeTool == AnnotationTool.eraser) {
                              setState(() {
                                _currentEraserPos = null;
                              });
                            } else if (_currentStroke != null) {
                              setState(() {
                                final densePoints = _currentStroke!.isStraightLine &&
                                        _currentStroke!.points.length >= 2
                                    ? _densifyPoints([
                                        _currentStroke!.points.first,
                                        _currentStroke!.points.last
                                      ])
                                    : _densifyPoints(_currentStroke!.points);

                                _strokes.add(Stroke(
                                  points: densePoints,
                                  color: _currentStroke!.color,
                                  strokeWidth: _currentStroke!.strokeWidth,
                                  isStraightLine:
                                      _currentStroke!.isStraightLine,
                                ));
                                _perPageStrokes[_currentPage] =
                                    List.from(_strokes);
                                _currentStroke = null;
                              });
                              _autoSaveAndSync();
                            }
                          },
                          onPanCancel: () {
                            if (_activeTool == AnnotationTool.eraser) {
                              setState(() {
                                _currentEraserPos = null;
                              });
                            } else if (_currentStroke != null) {
                              setState(() {
                                _currentStroke = null;
                              });
                            }
                          },
                          child: CustomPaint(
                            painter: BaseAnnotationPainter(
                              strokes: pageStrokes,
                              currentStroke: pageCurrentStroke,
                              activeTool: _activeTool,
                              penSubTool: _penSubTool,
                              eraserPos: isCurrent ? _currentEraserPos : null,
                              eraserMode: _eraserMode,
                              refWidth: refW,
                              refHeight: refH,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                    )
                  : CustomPaint(
                      painter: BaseAnnotationPainter(
                        strokes: pageStrokes,
                        currentStroke: null,
                        activeTool: AnnotationTool.none,
                        refWidth: refW,
                        refHeight: refH,
                      ),
                      size: Size.infinite,
                    ),
            ),

            // 3. Image Stickers (Photos)
            if (isCurrent)
              ...pageImages.map((annotation) {
                final isSel = _selectedImageId == annotation.id;
                return Positioned(
                  left: annotation.position.dx * scaleX,
                  top: isSel
                      ? (annotation.position.dy * scaleY) - 34
                      : (annotation.position.dy * scaleY),
                  child: _buildDraggableResizableImageWidget(
                    annotation,
                    scaleX: scaleX,
                    scaleY: scaleY,
                  ),
                );
              })
            else
              ...pageImages.map((annotation) {
                final isCircle = annotation.shape == 'circle';
                final isPolaroid = annotation.shape == 'polaroid';
                BorderRadius radius = BorderRadius.circular(16);
                if (annotation.shape == 'rectangle') {
                  radius = BorderRadius.circular(2);
                } else if (annotation.shape == 'pill') {
                  radius = BorderRadius.circular(32);
                } else if (isPolaroid) {
                  radius = BorderRadius.circular(6);
                }

                Border? border;
                if (annotation.border == 'purple') {
                  border = Border.all(color: AppTheme.primaryPurple, width: 2.5);
                } else if (annotation.border == 'dark') {
                  border = Border.all(color: const Color(0xFF1E293B), width: 2.0);
                } else if (annotation.border == 'white') {
                  border = Border.all(color: Colors.white, width: 2.0);
                }

                return Positioned(
                  left: annotation.position.dx * scaleX,
                  top: annotation.position.dy * scaleY,
                  child: Container(
                    width: (annotation.size.width * scaleX).clamp(20.0, 1200.0),
                    height: (annotation.size.height * scaleY).clamp(20.0, 1200.0),
                    padding: isPolaroid
                        ? const EdgeInsets.fromLTRB(6, 6, 6, 22)
                        : EdgeInsets.zero,
                    decoration: BoxDecoration(
                      color: isPolaroid ? Colors.white : Colors.transparent,
                      shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: isCircle ? null : radius,
                      border: border,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2D2640).withValues(alpha: 0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: isCircle
                        ? ClipOval(
                            child: Image.file(
                              File(annotation.imagePath),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  _buildImagePlaceholder(),
                            ),
                          )
                        : ClipRRect(
                            borderRadius: isPolaroid
                                ? BorderRadius.circular(4)
                                : radius,
                            child: Image.file(
                              File(annotation.imagePath),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  _buildImagePlaceholder(),
                            ),
                          ),
                  ),
                );
              }),

            // 4. Digital Text Notes (Saved Notes)
            ...pageTexts.map((annotation) {
              return Positioned(
                left: annotation.position.dx * scaleX,
                top: annotation.position.dy * scaleY,
                child: _buildDraggableTextWidget(
                  annotation,
                  scaleX: scaleX,
                  scaleY: scaleY,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Draggable & Resizable Image Sticker Widget locked to PDF
  Widget _buildDraggableResizableImageWidget(
    ImageAnnotation annotation, {
    required double scaleX,
    required double scaleY,
  }) {
    final isSelected = _selectedImageId == annotation.id;
    final isLocked = annotation.isLocked;

    // Determine shape styling
    BorderRadius borderRadius;
    BoxShape boxShape = BoxShape.rectangle;
    bool isCircle = false;
    bool isPolaroid = false;

    switch (annotation.shape) {
      case 'circle':
        boxShape = BoxShape.circle;
        borderRadius = BorderRadius.zero;
        isCircle = true;
        break;
      case 'rectangle':
        borderRadius = BorderRadius.circular(2);
        break;
      case 'pill':
        borderRadius = BorderRadius.circular(32);
        break;
      case 'polaroid':
        borderRadius = BorderRadius.circular(6);
        isPolaroid = true;
        break;
      case 'rounded':
      default:
        borderRadius = BorderRadius.circular(16);
        break;
    }

    // Determine border styling
    Border? border;
    switch (annotation.border) {
      case 'purple':
        border = Border.all(
          color: AppTheme.primaryPurple,
          width: isSelected ? 3.5 : 2.5,
        );
        break;
      case 'dark':
        border = Border.all(
          color: isSelected ? AppTheme.primaryPurple : const Color(0xFF1E293B),
          width: isSelected ? 3.0 : 2.0,
        );
        break;
      case 'none':
        border = isSelected
            ? Border.all(
                color: AppTheme.primaryPurple.withValues(alpha: 0.8),
                width: 2.0,
              )
            : null;
        break;
      case 'white':
      default:
        border = Border.all(
          color: isSelected ? AppTheme.primaryPurple : Colors.white,
          width: isSelected ? 3.0 : 2.0,
        );
        break;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1. Top Action Floating Bar (Ultra-Compact & Sleek)
        if (isSelected)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.surfaceWhite,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isLocked
                    ? const Color(0xFFF59E0B).withValues(alpha: 0.5)
                    : AppTheme.dividerColor,
              ),
              boxShadow: AppTheme.softShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isLocked) ...[
                  // 1. Drag Handle
                  Tooltip(
                    message: 'Drag Image',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (DragStartDetails details) {
                        _swipeStartPos = null;
                        _isDraggingAnnotation = true;
                        setState(() {
                          _selectedImageId = annotation.id;
                          _selectedTextId = null;
                        });
                      },
                      onPanUpdate: (DragUpdateDetails details) {
                        _swipeStartPos = null;
                        setState(() {
                          annotation.position += Offset(
                            details.delta.dx / scaleX,
                            details.delta.dy / scaleY,
                          );
                          _selectedImageId = annotation.id;
                          _selectedTextId = null;
                        });
                      },
                      onPanEnd: (_) {
                        _swipeStartPos = null;
                        _isDraggingAnnotation = false;
                        _autoSaveAndSync();
                      },
                      onPanCancel: () {
                        _swipeStartPos = null;
                        _isDraggingAnnotation = false;
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 7, vertical: 4.5),
                        child: Icon(
                          CupertinoIcons.move,
                          size: 14,
                          color: AppTheme.primaryPurple,
                        ),
                      ),
                    ),
                  ),

                  Container(
                    width: 1,
                    height: 12,
                    color: AppTheme.dividerColor,
                  ),

                  // 2. Crop Image Button
                  Tooltip(
                    message: 'Crop Image',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _openImageCropper(annotation);
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.5, vertical: 4.5),
                        child: Icon(
                          CupertinoIcons.crop,
                          size: 14,
                          color: AppTheme.primaryPurple,
                        ),
                      ),
                    ),
                  ),

                  Container(
                    width: 1,
                    height: 12,
                    color: AppTheme.dividerColor,
                  ),

                  // 3. AI Background Remover Button
                  Tooltip(
                    message: 'AI Background Remover',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _openImageBgRemover(annotation);
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.5, vertical: 4.5),
                        child: Icon(
                          CupertinoIcons.sparkles,
                          size: 14,
                          color: AppTheme.primaryPurple,
                        ),
                      ),
                    ),
                  ),

                  Container(
                    width: 1,
                    height: 12,
                    color: AppTheme.dividerColor,
                  ),
                ] else ...[
                  // Locked Indicator
                  const Tooltip(
                    message: 'Image is Locked',
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: 7, vertical: 4.5),
                      child: Icon(
                        CupertinoIcons.lock_fill,
                        size: 13,
                        color: Color(0xFFD97706),
                      ),
                    ),
                  ),

                  Container(
                    width: 1,
                    height: 12,
                    color: AppTheme.dividerColor,
                  ),
                ],

                // 4. Shape & Border Styling Button
                Tooltip(
                  message: 'Shape & Border',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openImageStylePicker(annotation),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: 6.5, vertical: 4.5),
                      child: Icon(
                        CupertinoIcons.paintbrush,
                        size: 14,
                        color: AppTheme.primaryPurple,
                      ),
                    ),
                  ),
                ),

                Container(
                  width: 1,
                  height: 12,
                  color: AppTheme.dividerColor,
                ),

                // 5. Lock / Unlock Toggle Button
                Tooltip(
                  message: isLocked ? 'Unlock Image' : 'Lock Image',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      setState(() {
                        annotation.isLocked = !annotation.isLocked;
                      });
                      _autoSaveAndSync();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                annotation.isLocked
                                    ? CupertinoIcons.lock_fill
                                    : CupertinoIcons.lock_open_fill,
                                size: 16,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 8),
                              Text(annotation.isLocked
                                  ? 'Image locked in place'
                                  : 'Image unlocked'),
                            ],
                          ),
                          backgroundColor: annotation.isLocked
                              ? const Color(0xFF1E293B)
                              : AppTheme.primaryPurple,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6.5, vertical: 4.5),
                      child: Icon(
                        isLocked
                            ? CupertinoIcons.lock_open
                            : CupertinoIcons.lock,
                        size: 14,
                        color: isLocked
                            ? AppTheme.primaryPurple
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),

                Container(
                  width: 1,
                  height: 12,
                  color: AppTheme.dividerColor,
                ),

                // 6. Revert / Undo BG Removal Button
                if (annotation.originalImagePath != null &&
                    annotation.originalImagePath != annotation.imagePath) ...[
                  Tooltip(
                    message: 'Undo BG Removal (Restore Original)',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        setState(() {
                          annotation.imagePath = annotation.originalImagePath!;
                          if (annotation.originalSize != null) {
                            annotation.size = annotation.originalSize!;
                          }
                        });
                        _autoSaveAndSync();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.arrow_counterclockwise,
                                    size: 16, color: Colors.white),
                                SizedBox(width: 8),
                                Text('Restored original image'),
                              ],
                            ),
                            backgroundColor: AppTheme.primaryPurple,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.5, vertical: 4.5),
                        child: Icon(
                          CupertinoIcons.arrow_counterclockwise,
                          size: 14,
                          color: Color(0xFFE11D48),
                        ),
                      ),
                    ),
                  ),

                  Container(
                    width: 1,
                    height: 12,
                    color: AppTheme.dividerColor,
                  ),
                ],

                // 7. Delete Image Button
                Tooltip(
                  message: 'Delete Image',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.heavyImpact();
                      _deleteImageAnnotation(annotation.id);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 3),
                      child: Container(
                        padding: const EdgeInsets.all(3.5),
                        decoration: const BoxDecoration(
                          color: Color(0xFFFEE2E2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          CupertinoIcons.trash_fill,
                          size: 12,
                          color: Color(0xFFEF4444),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 2. Base Image Container with Pan + Resize
        Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: isLocked
                  ? null
                  : (DragStartDetails details) {
                      _swipeStartPos = null;
                      _isDraggingAnnotation = true;
                      setState(() {
                        _selectedImageId = annotation.id;
                        _selectedTextId = null;
                      });
                    },
              onPanUpdate: isLocked
                  ? null
                  : (DragUpdateDetails details) {
                      _swipeStartPos = null;
                      setState(() {
                        annotation.position += Offset(
                          details.delta.dx / scaleX,
                          details.delta.dy / scaleY,
                        );
                        _selectedImageId = annotation.id;
                        _selectedTextId = null;
                      });
                    },
              onPanEnd: isLocked
                  ? null
                  : (_) {
                      _swipeStartPos = null;
                      _isDraggingAnnotation = false;
                      _autoSaveAndSync();
                    },
              onPanCancel: isLocked
                  ? null
                  : () {
                      _swipeStartPos = null;
                      _isDraggingAnnotation = false;
                    },
              onTap: () {
                setState(() {
                  _selectedImageId = isSelected ? null : annotation.id;
                  _selectedTextId = null;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                width: (annotation.size.width * scaleX).clamp(30.0, 1200.0),
                height: (annotation.size.height * scaleY).clamp(30.0, 1200.0),
                padding: isPolaroid
                    ? const EdgeInsets.fromLTRB(6, 6, 6, 22)
                    : EdgeInsets.zero,
                decoration: BoxDecoration(
                  color: isPolaroid ? Colors.white : Colors.transparent,
                  shape: boxShape,
                  borderRadius: isCircle ? null : borderRadius,
                  border: border,
                  boxShadow: [
                    BoxShadow(
                      color: isSelected
                          ? AppTheme.primaryPurple.withValues(alpha: 0.35)
                          : const Color(0xFF2D2640).withValues(alpha: 0.14),
                      blurRadius: isSelected ? 16 : 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: isCircle
                    ? ClipOval(
                        child: Image.file(
                          File(annotation.imagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _buildImagePlaceholder(),
                        ),
                      )
                    : ClipRRect(
                        borderRadius: isPolaroid
                            ? BorderRadius.circular(4)
                            : borderRadius,
                        child: Image.file(
                          File(annotation.imagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _buildImagePlaceholder(),
                        ),
                      ),
              ),
            ),

            // Bottom-Right Corner Resize Grip Handle (Hidden if Locked)
            if (isSelected && !isLocked)
              Positioned(
                right: -10,
                bottom: -10,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) {
                    _swipeStartPos = null;
                    _isDraggingAnnotation = true;
                  },
                  onPanUpdate: (DragUpdateDetails details) {
                    _swipeStartPos = null;
                    setState(() {
                      final newWidth = (annotation.size.width +
                              (details.delta.dx / scaleX))
                          .clamp(40.0, 800.0);
                      final newHeight = (annotation.size.height +
                              (details.delta.dy / scaleY))
                          .clamp(40.0, 800.0);
                      annotation.size = Size(newWidth, newHeight);
                    });
                  },
                  onPanEnd: (_) {
                    _swipeStartPos = null;
                    _isDraggingAnnotation = false;
                    _autoSaveAndSync();
                  },
                  onPanCancel: () {
                    _swipeStartPos = null;
                    _isDraggingAnnotation = false;
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
      ],
    );
  }

  /// Draggable Digital Text Note Widget locked to PDF
  Widget _buildDraggableTextWidget(
    TextAnnotation annotation, {
    required double scaleX,
    required double scaleY,
  }) {
    final isSelected = _selectedTextId == annotation.id;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) {
        _swipeStartPos = null;
        _isDraggingAnnotation = true;
        setState(() {
          _selectedTextId = annotation.id;
          _selectedImageId = null;
        });
      },
      onPanUpdate: (DragUpdateDetails details) {
        _swipeStartPos = null;
        setState(() {
          annotation.position += Offset(
            details.delta.dx / scaleX,
            details.delta.dy / scaleY,
          );
          _selectedTextId = annotation.id;
          _selectedImageId = null;
        });
      },
      onPanEnd: (_) {
        _swipeStartPos = null;
        _isDraggingAnnotation = false;
        _autoSaveAndSync();
      },
      onPanCancel: () {
        _swipeStartPos = null;
        _isDraggingAnnotation = false;
      },
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
        constraints: BoxConstraints(maxWidth: (280 * scaleX).clamp(180.0, 600.0)),
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
                fontSize: (annotation.fontSize * scaleX).clamp(8.0, 60.0),
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
            top: MediaQuery.of(context).padding.top + 6,
            bottom: 8,
            left: 14,
            right: 14,
          ),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xF8EDE7FD), // Soft Lilac / Purple tint
                Color(0xF8F4EFFE), // Soft Iris middle
                Color(0xF8FDE8EE), // Soft Blush Pink tint
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border(
              bottom: BorderSide(
                color: AppTheme.primaryPurple.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primaryPurple.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: Back Button & Full Title View
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Back Button
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWhite,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.primaryPurpleLight,
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.06),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        CupertinoIcons.chevron_back,
                        color: AppTheme.primaryPurple,
                        size: 18,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Full Title
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                        letterSpacing: -0.2,
                        height: 1.25,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Collapse Header Button (Maximize Reading Space)
                  Tooltip(
                    message: 'Hide Header (Maximize Reading Space)',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _isHeaderVisible = false);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppTheme.primaryPurple
                                    .withValues(alpha: 0.25)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.chevron_up,
                                color: AppTheme.primaryPurple,
                                size: 14,
                              ),
                              SizedBox(width: 3),
                              Text(
                                'Hide',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primaryPurple,
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

              const SizedBox(height: 6),

              // Row 2 / Next Space: Page Badge + Undo/Redo + Delete/Clear + Sync Status
              Row(
                children: [
                  // Page Count Badge (Always visible, e.g. Page 1 of 1, No Icon, Bold)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4.5),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWhite,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.primaryPurpleLight,
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.06),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Text(
                      'Page $_currentPage of ${_pageCount < 1 ? 1 : _pageCount}',
                      style: const TextStyle(
                        fontFamily: 'OpenSauceSans',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ),

                  const Spacer(),

                  // Undo & Redo Capsule Group
                  Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWhite,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.primaryPurpleLight,
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Undo Button
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 28, minHeight: 28),
                          icon: Icon(
                            CupertinoIcons.arrow_uturn_left,
                            color: (_undoStack.isNotEmpty || _strokes.isNotEmpty)
                                ? AppTheme.primaryPurple
                                : AppTheme.textMuted.withValues(alpha: 0.35),
                            size: 16,
                          ),
                          tooltip: 'Undo (↩)',
                          onPressed: (_undoStack.isNotEmpty || _strokes.isNotEmpty)
                              ? _undo
                              : null,
                        ),
                        Container(
                          width: 1,
                          height: 14,
                          color: AppTheme.primaryPurpleLight,
                        ),
                        // Redo Button
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 28, minHeight: 28),
                          icon: Icon(
                            CupertinoIcons.arrow_uturn_right,
                            color: _redoStack.isNotEmpty
                                ? AppTheme.primaryPurple
                                : AppTheme.textMuted.withValues(alpha: 0.35),
                            size: 16,
                          ),
                          tooltip: 'Redo (↪)',
                          onPressed: _redoStack.isNotEmpty ? _redo : null,
                        ),
                      ],
                    ),
                  ),

                  // Delete Selected Image Sticker Button
                  if (_selectedImageId != null) ...[
                    const SizedBox(width: 5),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: const BoxDecoration(
                          color: Color(0xFFFEE2E2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          CupertinoIcons.trash_fill,
                          color: Color(0xFFEF4444),
                          size: 14,
                        ),
                      ),
                      tooltip: 'Delete Selected Image',
                      onPressed: () {
                        HapticFeedback.heavyImpact();
                        _deleteImageAnnotation(_selectedImageId!);
                      },
                    ),
                  ],

                  // Clear Annotations Button
                  if (totalAnnotationsCount > 0 && _selectedImageId == null) ...[
                    const SizedBox(width: 5),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: AppTheme.accentPinkLight.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          CupertinoIcons.trash,
                          color: AppTheme.accentPink,
                          size: 14,
                        ),
                      ),
                      tooltip: 'Clear Annotations',
                      onPressed: _clearAnnotations,
                    ),
                  ],

                  const SizedBox(width: 4),

                  // Smart Auto-Sync Status Badge / Manual Sync Trigger
                  _buildSyncStatusBadge(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Floating Mini Header Unhide Bubble (displayed when top header is hidden)
  Widget _buildFloatingUnhideHeaderButton() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.8),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1E1B4B).withValues(alpha: 0.12),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Back Button
              IconButton(
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(
                  CupertinoIcons.chevron_back,
                  color: AppTheme.primaryPurple,
                  size: 18,
                ),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
              ),
              Container(
                width: 1,
                height: 18,
                color: AppTheme.dividerColor,
              ),
              // Show Header Button
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(24),
                  ),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _isHeaderVisible = true);
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          CupertinoIcons.chevron_down,
                          color: AppTheme.primaryPurple,
                          size: 15,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Show Header',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryPurpleDark,
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
    );
  }

  /// Interactive Auto-Sync Badge showing real-time Cloud / Local status
  Widget _buildSyncStatusBadge() {
    Widget icon;
    String label;
    Color bgColor;
    Color textColor;
    Color borderColor;

    switch (_syncStatus) {
      case SyncStatus.synced:
        icon = const Icon(CupertinoIcons.cloud_upload_fill,
            color: Color(0xFF10B981), size: 14);
        label = 'Synced';
        bgColor = const Color(0xFFECFDF5);
        textColor = const Color(0xFF065F46);
        borderColor = const Color(0xFF10B981).withValues(alpha: 0.3);
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
        borderColor = AppTheme.primaryPurple.withValues(alpha: 0.3);
        break;
      case SyncStatus.savedLocally:
        icon = const Icon(CupertinoIcons.checkmark_circle_fill,
            color: AppTheme.primaryPurple, size: 14);
        label = 'Saved';
        bgColor = AppTheme.primaryPurpleLight;
        textColor = AppTheme.primaryPurpleDark;
        borderColor = AppTheme.primaryPurple.withValues(alpha: 0.3);
        break;
      case SyncStatus.offline:
        icon = const Icon(CupertinoIcons.bolt_fill,
            color: Color(0xFFF59E0B), size: 14);
        label = 'Offline';
        bgColor = const Color(0xFFFFFBEB);
        textColor = const Color(0xFFB45309);
        borderColor = const Color(0xFFF59E0B).withValues(alpha: 0.3);
        break;
    }

    return Container(
      height: 32,
      margin: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: textColor.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
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
                    ? 'Saved locally (Offline mode)'
                    : 'Synced to Supabase Cloud'),
                duration: const Duration(seconds: 1),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'OpenSauceSans',
                    color: textColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1,
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
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(36),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.surfaceWhite.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(36),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.8),
                  width: 1.5,
                ),
                boxShadow: AppTheme.floatingToolbarShadow,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
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

                    const SizedBox(width: 2),
                    _buildVerticalDivider(),
                    const SizedBox(width: 2),

                    // 1. Freehand Pen / Highlighter
                    _buildToolButton(
                      tool: AnnotationTool.highlighter,
                      icon: _penSubTool == PenSubTool.ballpen
                          ? CupertinoIcons.pen
                          : CupertinoIcons.pencil_outline,
                      label: _penSubTool == PenSubTool.ballpen
                          ? 'Ballpen'
                          : 'Highlighter',
                      tooltip: _penSubTool == PenSubTool.ballpen
                          ? 'Freehand Ballpen Drawing'
                          : 'Freehand Highlighter',
                    ),

                    const SizedBox(width: 2),

                    // 2. Straight Line
                    _buildToolButton(
                      tool: AnnotationTool.straightLine,
                      icon: CupertinoIcons.line_horizontal_3_decrease,
                      label: 'Line',
                      tooltip: _penSubTool == PenSubTool.ballpen
                          ? 'Auto-Straightened Ballpen Line'
                          : 'Auto-Straightened Highlighter Line',
                    ),

                    const SizedBox(width: 2),
                    _buildVerticalDivider(),
                    const SizedBox(width: 2),

                    // 3. Add Image (Gallery Picker + Resize)
                    _buildToolButton(
                      tool: AnnotationTool.addImage,
                      icon: CupertinoIcons.photo,
                      label: 'Image',
                      tooltip: 'Insert Image / Screenshot',
                    ),

                    const SizedBox(width: 2),
                    _buildVerticalDivider(),
                    const SizedBox(width: 2),

                    // Screen Orientation Switcher (Portrait / Landscape)
                    Tooltip(
                      message: MediaQuery.of(context).orientation ==
                              Orientation.landscape
                          ? 'Landscape Mode (Tap to rotate)'
                          : 'Portrait Mode (Tap to rotate)',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(28),
                          onTap: _toggleScreenOrientation,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 6,
                            ),
                            child: Icon(
                              MediaQuery.of(context).orientation ==
                                      Orientation.landscape
                                  ? CupertinoIcons.device_phone_landscape
                                  : CupertinoIcons.device_phone_portrait,
                              size: 18,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Multi-page Slide Direction Switcher (Positioned on the outer edge)
                    if (_pageCount > 1) ...[
                      const SizedBox(width: 2),
                      Tooltip(
                        message: _slideOrientation ==
                                PageSlideOrientation.vertical
                            ? 'Vertical Scroll (Tap for Horizontal)'
                            : 'Horizontal Slide (Tap for Vertical)',
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(28),
                            onTap: _toggleSlideOrientation,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 6,
                              ),
                              child: Icon(
                                _slideOrientation ==
                                        PageSlideOrientation.vertical
                                    ? CupertinoIcons.arrow_up_down
                                    : CupertinoIcons.arrow_left_right,
                                size: 18,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(width: 2),
                    _buildVerticalDivider(),
                    const SizedBox(width: 2),

                    // Hide / Collapse Toolbar Button (Maximize Canvas Space)
                    Tooltip(
                      message: 'Hide Tools (Maximize Canvas Space)',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(28),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _isToolbarVisible = false);
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            child: Icon(
                              CupertinoIcons.chevron_down,
                              size: 16,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Floating Mini Tools Unhide Pill (displayed when bottom toolbar is collapsed)
  Widget _buildFloatingUnhideToolbarButton() {
    IconData activeIcon = CupertinoIcons.hand_draw;
    String activeName = 'Navigate';
    if (_activeTool == AnnotationTool.highlighter) {
      activeIcon = _penSubTool == PenSubTool.ballpen
          ? CupertinoIcons.pen
          : CupertinoIcons.pencil_outline;
      activeName =
          _penSubTool == PenSubTool.ballpen ? 'Ballpen' : 'Highlighter';
    } else if (_activeTool == AnnotationTool.straightLine) {
      activeIcon = CupertinoIcons.line_horizontal_3_decrease;
      activeName = 'Line';
    } else if (_activeTool == AnnotationTool.eraser) {
      activeIcon = CupertinoIcons.scribble;
      activeName = 'Eraser';
    } else if (_activeTool == AnnotationTool.addImage) {
      activeIcon = CupertinoIcons.photo;
      activeName = 'Image';
    }

    final isDrawing = _activeTool == AnnotationTool.highlighter ||
        _activeTool == AnnotationTool.straightLine;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.8),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1E1B4B).withValues(alpha: 0.14),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _isToolbarVisible = true);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isDrawing) ...[
                      Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: _selectedColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Icon(
                      activeIcon,
                      color: AppTheme.primaryPurple,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      activeName,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryPurpleDark,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 1,
                      height: 14,
                      color: AppTheme.dividerColor,
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      CupertinoIcons.chevron_up,
                      color: AppTheme.primaryPurple,
                      size: 14,
                    ),
                    const SizedBox(width: 3),
                    const Text(
                      'Tools',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryPurpleDark,
                      ),
                    ),
                  ],
                ),
              ),
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
    final isSelected = _activeTool == tool ||
        (_activeTool == AnnotationTool.eraser && tool == _previousDrawingTool);

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
              horizontal: isSelected ? 10 : 7,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              gradient: isSelected ? AppTheme.primaryGradientDiagonal : null,
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
                  size: 18,
                  color: isSelected ? Colors.white : AppTheme.textSecondary,
                ),
                if (isSelected) ...[
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11.5,
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

  /// Floating options bubble that sits directly on top of the Highlighter/Pen icon (Stroke Thickness)
  Widget _buildFloatingThicknessOptionsBubble() {
    final isPen = _penSubTool == PenSubTool.ballpen;
    final activeWidth = isPen ? _ballpenWidth : _highlighterWidth;

    // Presets tailored specifically to each tool
    final List<Map<String, dynamic>> thicknessPresets = isPen
        ? [
            {'label': 'Fine', 'width': 1.5},
            {'label': 'Regular', 'width': 3.0},
            {'label': 'Medium', 'width': 5.0},
            {'label': 'Bold', 'width': 8.0},
          ]
        : [
            {'label': 'Light', 'width': 10.0},
            {'label': 'Medium', 'width': 16.0},
            {'label': 'Broad', 'width': 24.0},
            {'label': 'Chisel', 'width': 32.0},
          ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppTheme.primaryPurple.withValues(alpha: 0.3),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primaryPurple.withValues(alpha: 0.14),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: const Color(0xFF1E1B4B).withValues(alpha: 0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tool Name & Current Thickness Live Badge
                Padding(
                  padding: const EdgeInsets.only(left: 3, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isPen
                            ? CupertinoIcons.pen
                            : CupertinoIcons.pencil_outline,
                        size: 13,
                        color: AppTheme.primaryPurple,
                      ),
                      const SizedBox(width: 3.5),
                      Text(
                        '${activeWidth % 1 == 0 ? activeWidth.toInt() : activeWidth}px',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.primaryPurple,
                        ),
                      ),
                    ],
                  ),
                ),

                _buildVerticalDivider(),
                const SizedBox(width: 3),

                // Thickness Preset Pills
                ...thicknessPresets.map((preset) {
                  final double width = preset['width'] as double;
                  final String label = preset['label'] as String;
                  final isSelected = (activeWidth - width).abs() < 1.0;

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Tooltip(
                      message:
                          '$label (${width % 1 == 0 ? width.toInt() : width}px)',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            if (isPen) {
                              _ballpenWidth = width;
                            } else {
                              _highlighterWidth = width;
                            }
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7.5, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppTheme.primaryPurple
                                : const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: AppTheme.primaryPurple
                                          .withValues(alpha: 0.35),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Visual Dot
                              Container(
                                width: (width / (isPen ? 1.5 : 3.5))
                                    .clamp(3.0, 7.5),
                                height: (width / (isPen ? 1.5 : 3.5))
                                    .clamp(3.0, 7.5),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Colors.white
                                      : AppTheme.textPrimary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 3.5),
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: isSelected
                                      ? Colors.white
                                      : AppTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),

                const SizedBox(width: 3),
                _buildVerticalDivider(),
                const SizedBox(width: 2),

                // Collapse / Close Button
                Tooltip(
                  message: 'Collapse Thickness Options',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        HapticFeedback.lightImpact();
                        setState(() => _isThicknessMenuExpanded = false);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(4.5),
                        decoration: const BoxDecoration(
                          color: Color(0xFFF3F4F6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          CupertinoIcons.chevron_down,
                          size: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Floating options bubble that sits directly on top of the Eraser icon
  Widget _buildFloatingEraserOptionsBubble() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFEF4444).withValues(alpha: 0.3),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFEF4444).withValues(alpha: 0.14),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: const Color(0xFF1E1B4B).withValues(alpha: 0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 1. Draw Erase (Precision carving)
                _buildEraserModePill(
                  mode: EraserMode.drawErase,
                  icon: CupertinoIcons.scribble,
                  label: 'Draw Erase',
                  tooltip: 'Precision: Erase only what you draw across',
                ),

                const SizedBox(width: 4),

                // 2. Wipe Erase (Whole line wiping)
                _buildEraserModePill(
                  mode: EraserMode.wipeStroke,
                  icon: CupertinoIcons.trash_fill,
                  label: 'Wipe Erase',
                  tooltip: 'Wipe: Erase whole line on contact',
                ),

                const SizedBox(width: 6),
                _buildVerticalDivider(),
                const SizedBox(width: 3),

                // 3. Collapse / Close Button
                Tooltip(
                  message: 'Collapse Options',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        HapticFeedback.lightImpact();
                        setState(() => _isEraserMenuExpanded = false);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: const BoxDecoration(
                          color: Color(0xFFF3F4F6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          CupertinoIcons.chevron_down,
                          size: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens a modern modal bottom sheet with 24 custom colors to choose from
  void _openCustomColorPicker() {
    // 24 Curated Stationery & Highlighter Tones
    const List<Color> customSpectrum = [
      // Neutrals & Darks
      Color(0xFF0F172A), // Midnight Black
      Color(0xFF475569), // Slate Grey
      Color(0xFF78350F), // Espresso Brown
      Color(0xFFB45309), // Amber Brown
      Color(0xFFD97706), // Warm Orange
      Color(0xFFF59E0B), // Vibrant Gold
      // Greens & Teals
      Color(0xFF14532D), // Forest Green
      Color(0xFF16A34A), // Emerald
      Color(0xFF22C55E), // Fresh Green
      Color(0xFF86EFAC), // Soft Mint
      Color(0xFF0D9488), // Deep Teal
      Color(0xFF14B8A6), // Aqua Teal
      // Blues & Purples
      Color(0xFF0284C7), // Sky Blue
      Color(0xFF2563EB), // Royal Blue
      Color(0xFF1D4ED8), // Cobalt Blue
      Color(0xFF4F46E5), // Indigo
      Color(0xFF7C3AED), // Violet
      Color(0xFF9333EA), // Purple
      // Pinks & Reds
      Color(0xFFC026D3), // Fuchsia
      Color(0xFFDB2777), // Magenta Pink
      Color(0xFFF43F5E), // Coral Rose
      Color(0xFFE11D48), // Crimson
      Color(0xFFDC2626), // Bold Red
      Color(0xFFEA580C), // Tangy Orange
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Color(0x221E1B4B),
                blurRadius: 30,
                offset: Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top drag pill
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),

              // Title Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.palette_rounded,
                          size: 20, color: AppTheme.primaryPurple),
                      SizedBox(width: 8),
                      Text(
                        'Choose Custom Color',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(CupertinoIcons.xmark_circle_fill,
                        size: 22, color: AppTheme.textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // 24 Swatches Grid
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: customSpectrum.map((color) {
                  final colorWithAlpha = color.withValues(alpha: 0.4);
                  final isSelected = (_selectedColor.toARGB32() & 0x00FFFFFF) ==
                      (color.toARGB32() & 0x00FFFFFF);

                  return GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _customColor = colorWithAlpha;
                        _selectedColor = colorWithAlpha;
                        if (_activeTool == AnnotationTool.eraser) {
                          _activeTool = _previousDrawingTool;
                          _isThicknessMenuExpanded = true;
                        }
                      });
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? AppTheme.textPrimary
                              : Colors.white,
                          width: isSelected ? 3.0 : 2.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: color.withValues(alpha: 0.35),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: isSelected
                          ? const Icon(
                              CupertinoIcons.checkmark,
                              size: 18,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Secondary floating color palette & tool presets picker
  Widget _buildColorPickerSubBar() {
    // List of active dots: 5 presets + optional active custom color
    final List<Color> activeColorDots = [
      ...AppTheme.highlighterColors,
      if (_customColor != null &&
          !AppTheme.highlighterColors.any((c) =>
              (c.toARGB32() & 0x00FFFFFF) ==
              (_customColor!.toARGB32() & 0x00FFFFFF)))
        _customColor!,
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.dividerColor),
            boxShadow: AppTheme.softShadow,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Color Dots
                ...activeColorDots.map((color) {
                  final isSelected =
                      (_selectedColor.toARGB32() & 0x00FFFFFF) ==
                              (color.toARGB32() & 0x00FFFFFF) &&
                          _activeTool != AnnotationTool.eraser;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedColor = color;
                        if (_activeTool == AnnotationTool.eraser) {
                          _activeTool = _previousDrawingTool;
                          _isThicknessMenuExpanded = true;
                        }
                      });
                    },
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3.5),
                      width: 25,
                      height: 25,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 1.0),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color:
                              isSelected ? AppTheme.textPrimary : Colors.white,
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

                // Custom Rainbow Color Wheel Button
                Tooltip(
                  message: 'Custom Color Palette',
                  child: GestureDetector(
                    onTap: _openCustomColorPicker,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3.5),
                      width: 25,
                      height: 25,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const SweepGradient(
                          colors: [
                            Color(0xFFEF4444),
                            Color(0xFFF59E0B),
                            Color(0xFF10B981),
                            Color(0xFF06B6D4),
                            Color(0xFF6366F1),
                            Color(0xFFEC4899),
                            Color(0xFFEF4444),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            CupertinoIcons.plus,
                            size: 9,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 5),
                _buildVerticalDivider(),
                const SizedBox(width: 5),

                // 1. Ballpen Icon (Independent Ballpen tool)
                _buildSubBarPresetIcon(
                  icon: CupertinoIcons.pen,
                  tooltip: _activeTool == AnnotationTool.straightLine
                      ? 'Straight Ballpen (Fine Pen)'
                      : 'Ballpen (Fine Pen Stroke)',
                  isSelected: _activeTool != AnnotationTool.eraser &&
                      _penSubTool == PenSubTool.ballpen,
                  onTap: () {
                    setState(() {
                      if (_activeTool == AnnotationTool.eraser) {
                        _activeTool = _previousDrawingTool;
                        _penSubTool = PenSubTool.ballpen;
                        _isThicknessMenuExpanded = true;
                      } else if (_penSubTool == PenSubTool.ballpen) {
                        _isThicknessMenuExpanded = !_isThicknessMenuExpanded;
                      } else {
                        _penSubTool = PenSubTool.ballpen;
                        _isThicknessMenuExpanded = true;
                      }
                    });
                  },
                ),

                // 2. Highlighter Icon (Independent Highlighter tool)
                _buildSubBarPresetIcon(
                  icon: CupertinoIcons.pencil_outline,
                  tooltip: _activeTool == AnnotationTool.straightLine
                      ? 'Straight Highlighter (Marker)'
                      : 'Highlighter (Marker Stroke)',
                  isSelected: _activeTool != AnnotationTool.eraser &&
                      _penSubTool == PenSubTool.highlighter,
                  onTap: () {
                    setState(() {
                      if (_activeTool == AnnotationTool.eraser) {
                        _activeTool = _previousDrawingTool;
                        _penSubTool = PenSubTool.highlighter;
                        _isThicknessMenuExpanded = true;
                      } else if (_penSubTool == PenSubTool.highlighter) {
                        _isThicknessMenuExpanded = !_isThicknessMenuExpanded;
                      } else {
                        _penSubTool = PenSubTool.highlighter;
                        _isThicknessMenuExpanded = true;
                      }
                    });
                  },
                ),

                // 3. Eraser Icon (Toggles / Expands floating options above)
                _buildSubBarPresetIcon(
                  icon: CupertinoIcons.bandage,
                  tooltip: _activeTool == AnnotationTool.eraser
                      ? (_isEraserMenuExpanded
                          ? 'Collapse Eraser Options'
                          : 'Expand Eraser Options')
                      : 'Eraser (Open Options)',
                  isSelected: _activeTool == AnnotationTool.eraser,
                  selectedColor: const Color(0xFFEF4444),
                  onTap: () {
                    setState(() {
                      if (_activeTool == AnnotationTool.eraser) {
                        _isEraserMenuExpanded = !_isEraserMenuExpanded;
                      } else {
                        if (_activeTool == AnnotationTool.highlighter ||
                            _activeTool == AnnotationTool.straightLine) {
                          _previousDrawingTool = _activeTool;
                        }
                        _activeTool = AnnotationTool.eraser;
                        _isEraserMenuExpanded = true;
                      }
                    });
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Eraser mode pill tab button (Draw Erase vs Wipe Stroke)
  Widget _buildEraserModePill({
    required EraserMode mode,
    required IconData icon,
    required String label,
    required String tooltip,
  }) {
    final isSelected = _eraserMode == mode;

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _eraserMode = mode);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFFEF4444)
                : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(16),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: isSelected ? Colors.white : AppTheme.textPrimary,
              ),
              const SizedBox(width: 5),
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
      ),
    );
  }

  Widget _buildSubBarPresetIcon({
    required IconData icon,
    required String tooltip,
    required bool isSelected,
    required VoidCallback onTap,
    Color? selectedColor,
  }) {
    final activeBg = selectedColor ?? AppTheme.primaryPurple;

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: activeBg.withValues(alpha: 0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: 16,
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
}

/// Annotation Painter rendering freehand highlighter curves, straight lines, pen/marker nib indicator, and live eraser cursor
class BaseAnnotationPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final AnnotationTool activeTool;
  final PenSubTool? penSubTool;
  final Offset? eraserPos;
  final EraserMode? eraserMode;
  final double refWidth;
  final double refHeight;

  BaseAnnotationPainter({
    required this.strokes,
    required this.currentStroke,
    required this.activeTool,
    this.penSubTool,
    this.eraserPos,
    this.eraserMode,
    this.refWidth = 595.0,
    this.refHeight = 842.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double safeRefW = refWidth > 0 ? refWidth : 595.0;
    final double safeRefH = refHeight > 0 ? refHeight : 842.0;

    canvas.save();
    canvas.scale(size.width / safeRefW, size.height / safeRefH);

    // 1. Draw all committed historical strokes
    for (final stroke in strokes) {
      _renderStroke(canvas, stroke);
    }

    // 2. Draw currently active drag stroke (with live preview)
    if (currentStroke != null) {
      _renderStroke(canvas, currentStroke!);

      // 3. Draw live Pen / Marker Stylus Tip Nib while actively writing
      if (currentStroke!.points.isNotEmpty) {
        final tipPos = currentStroke!.points.last;
        final isPen = penSubTool == PenSubTool.ballpen;
        final isStraightLine = activeTool == AnnotationTool.straightLine ||
            currentStroke!.isStraightLine;
        _renderStylusNib(
          canvas,
          tipPos,
          currentStroke!.strokeWidth,
          currentStroke!.color,
          isPen,
          isStraightLine,
        );
      }
    }

    // 4. Draw live Eraser cursor indicator while actively erasing
    if (activeTool == AnnotationTool.eraser && eraserPos != null) {
      final isWipe = eraserMode == EraserMode.wipeStroke;
      final double cursorRadius = isWipe ? 14.0 : 10.0;

      final eraserRingPaint = Paint()
        ..color = const Color(0xFFEF4444).withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isWipe ? 2.0 : 1.5;

      final eraserFillPaint = Paint()
        ..color = const Color(0xFFFEE2E2).withValues(alpha: isWipe ? 0.45 : 0.55)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(eraserPos!, cursorRadius, eraserFillPaint);
      canvas.drawCircle(eraserPos!, cursorRadius, eraserRingPaint);
    }

    canvas.restore();
  }

  /// Renders a dynamic stylus nib / pen marker indicator at the active writing tip
  void _renderStylusNib(
    Canvas canvas,
    Offset tipPos,
    double strokeWidth,
    Color color,
    bool isPen,
    bool isStraightLine,
  ) {
    if (isStraightLine) {
      // Precision Crosshair / Compass Stylus Tip for Straight Line
      final crosshairPaint = Paint()
        ..color = color.withValues(alpha: 1.0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      final centerDotPaint = Paint()
        ..color = color.withValues(alpha: 1.0)
        ..style = PaintingStyle.fill;

      final double r = (strokeWidth / 2 + 4.0).clamp(6.0, 16.0);

      // Outer Guide Ring
      canvas.drawCircle(tipPos, r, crosshairPaint);
      // Center Precision Dot
      canvas.drawCircle(tipPos, 2.5, centerDotPaint);
      // 4-Axis Crosshair ticks
      canvas.drawLine(
          Offset(tipPos.dx - r - 3, tipPos.dy), Offset(tipPos.dx - r + 1, tipPos.dy), crosshairPaint);
      canvas.drawLine(
          Offset(tipPos.dx + r - 1, tipPos.dy), Offset(tipPos.dx + r + 3, tipPos.dy), crosshairPaint);
      canvas.drawLine(
          Offset(tipPos.dx, tipPos.dy - r - 3), Offset(tipPos.dx, tipPos.dy - r + 1), crosshairPaint);
      canvas.drawLine(
          Offset(tipPos.dx, tipPos.dy + r - 1), Offset(tipPos.dx, tipPos.dy + r + 3), crosshairPaint);
    } else if (isPen) {
      // Precision Ballpen Stylus Nib (Fine pen point with glowing halo ring)
      final haloPaint = Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;

      final ringPaint = Paint()
        ..color = color.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      final centerPointPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;

      final tipRadius = (strokeWidth / 2 + 3.0).clamp(4.5, 9.0);

      // Glowing outer halo
      canvas.drawCircle(tipPos, tipRadius + 3.0, haloPaint);
      // Stylus Ring
      canvas.drawCircle(tipPos, tipRadius, ringPaint);
      // Center fine point
      canvas.drawCircle(tipPos, 1.8, centerPointPaint);
    } else {
      // Highlighter / Marker Chisel Nib (Translucent footprint with marker edge)
      final markerFootprintPaint = Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill;

      final markerRingPaint = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;

      final markerCenterDotPaint = Paint()
        ..color = color.withValues(alpha: 1.0)
        ..style = PaintingStyle.fill;

      final tipRadius = (strokeWidth / 2).clamp(5.0, 20.0);

      // Live footprint preview
      canvas.drawCircle(tipPos, tipRadius, markerFootprintPaint);
      // Sharp marker outline
      canvas.drawCircle(tipPos, tipRadius, markerRingPaint);
      // Center guide dot
      canvas.drawCircle(tipPos, 2.5, markerCenterDotPaint);
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
