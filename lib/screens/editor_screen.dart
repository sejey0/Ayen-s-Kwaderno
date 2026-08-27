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

/// Supported annotation tool types in document editor
enum AnnotationTool {
  none, // Pan & Zoom Navigation Mode
  highlighter, // Semi-transparent highlighter drawing
  straightLine, // Auto-straightened coordinate lines
  addImage, // Draggable/resizable image overlay
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
  Color _selectedColor = AppTheme.highlighterColors[0];
  double _strokeWidth = 14.0;

  // Slide Orientation State (Default: Vertical)
  PageSlideOrientation _slideOrientation = PageSlideOrientation.vertical;

  // Per-Page Annotation Storage Maps
  final Map<int, List<Stroke>> _perPageStrokes = {};
  final Map<int, List<TextAnnotation>> _perPageTextAnnotations = {};
  final Map<int, List<ImageAnnotation>> _perPageImageAnnotations = {};

  // Active Page Drawing strokes state
  final List<Stroke> _strokes = [];
  final List<Stroke> _redoHistory = [];
  Stroke? _currentStroke;

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
      _redoHistory.clear();
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
      final authUserId = client.auth.currentUser?.id ?? activeUserId;

      dynamic response;
      try {
        response = await client
            .from('document_annotations')
            .select()
            .eq('document_name', _documentIdentifier)
            .eq('user_id', authUserId)
            .maybeSingle();
      } catch (_) {
        response = await client
            .from('document_annotations')
            .select()
            .eq('document_name', _documentIdentifier)
            .maybeSingle();
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
      final authUserId = client.auth.currentUser?.id ?? activeUserId;

      final payload = {
        'user_id': authUserId,
        'document_name': _documentIdentifier,
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

    setState(() {
      _activeTool = tool;
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
    final bool isPaletteOpen = _activeTool == AnnotationTool.highlighter ||
        _activeTool == AnnotationTool.straightLine;
    final double bottomVerticalArrowOffset = isPaletteOpen ? 180.0 : 96.0;

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

            // ==========================================
            // FLOATING PAGE NAVIGATION CONTROLS
            // (Side-by-side arrows for Horizontal; Up & Down arrows for Vertical)
            // ==========================================
            if (_pageCount > 1) ...[
              if (_slideOrientation == PageSlideOrientation.horizontal) ...[
                // Left Floating Arrow (Side-by-side Prev)
                if (_currentPage > 1)
                  Positioned(
                    left: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _buildFloatingNavArrowButton(
                        icon: CupertinoIcons.chevron_left,
                        onTap: () => _goToPage(_currentPage - 1),
                      ),
                    ),
                  ),

                // Right Floating Arrow (Side-by-side Next)
                if (_currentPage < _pageCount)
                  Positioned(
                    right: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _buildFloatingNavArrowButton(
                        icon: CupertinoIcons.chevron_right,
                        onTap: () => _goToPage(_currentPage + 1),
                      ),
                    ),
                  ),
              ] else ...[
                // Top Floating Arrow (Up & Down Prev)
                if (_currentPage > 1)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 76,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _buildFloatingNavArrowButton(
                        icon: CupertinoIcons.chevron_up,
                        onTap: () => _goToPage(_currentPage - 1),
                      ),
                    ),
                  ),

                // Bottom Floating Arrow (Up & Down Next)
                if (_currentPage < _pageCount)
                  Positioned(
                    bottom: bottomVerticalArrowOffset,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _buildFloatingNavArrowButton(
                        icon: CupertinoIcons.chevron_down,
                        onTap: () => _goToPage(_currentPage + 1),
                      ),
                    ),
                  ),
              ],
            ],

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
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (DragStartDetails details) {
                          if (_activeTool == AnnotationTool.highlighter ||
                              _activeTool == AnnotationTool.straightLine) {
                            setState(() {
                              _redoHistory.clear();
                              _currentStroke = Stroke(
                                points: [details.localPosition],
                                color: _selectedColor,
                                strokeWidth: _strokeWidth,
                                isStraightLine:
                                    _activeTool == AnnotationTool.straightLine,
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
                              _perPageStrokes[_currentPage] =
                                  List.from(_strokes);
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
                            strokes: pageStrokes,
                            currentStroke: pageCurrentStroke,
                            activeTool: _activeTool,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    )
                  : CustomPaint(
                      painter: BaseAnnotationPainter(
                        strokes: pageStrokes,
                        currentStroke: null,
                        activeTool: AnnotationTool.none,
                      ),
                      size: Size.infinite,
                    ),
            ),

            // 3. Image Stickers (Photos)
            if (isCurrent)
              ...pageImages.map((annotation) {
                return Positioned(
                  left: annotation.position.dx,
                  top: annotation.position.dy,
                  child: _buildDraggableResizableImageWidget(annotation),
                );
              })
            else
              ...pageImages.map((annotation) {
                return Positioned(
                  left: annotation.position.dx,
                  top: annotation.position.dy,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.file(
                      File(annotation.imagePath),
                      width: annotation.size.width,
                      height: annotation.size.height,
                      fit: BoxFit.cover,
                    ),
                  ),
                );
              }),

            // 4. Digital Text Notes (Saved Notes)
            ...pageTexts.map((annotation) {
              return Positioned(
                left: annotation.position.dx,
                top: annotation.position.dy,
                child: _buildDraggableTextWidget(annotation),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Universal Floating Circular Navigation Arrow Button (used for both Horizontal and Vertical modes)
  Widget _buildFloatingNavArrowButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        shape: BoxShape.circle,
        border: Border.all(
          color: AppTheme.primaryPurple.withValues(alpha: 0.4),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E1B4B).withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: AppTheme.primaryPurple.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          child: Center(
            child: Icon(
              icon,
              size: 24,
              color: AppTheme.primaryPurpleDark,
            ),
          ),
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

              // Title
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.2,
                  ),
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

                // Multi-page Slide Direction Switcher (Icon-only matching toolbar style)
                if (_pageCount > 1) ...[
                  const SizedBox(width: 2),
                  Tooltip(
                    message: _slideOrientation == PageSlideOrientation.vertical
                        ? 'Vertical Scroll Mode (Tap for Horizontal ↔)'
                        : 'Horizontal Slide Mode (Tap for Vertical ↕)',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(28),
                        onTap: _toggleSlideOrientation,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Icon(
                            _slideOrientation == PageSlideOrientation.vertical
                                ? CupertinoIcons.arrow_up_down
                                : CupertinoIcons.arrow_left_right,
                            size: 20,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],

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

                // 3. Add Image (Gallery Picker + Resize)
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
