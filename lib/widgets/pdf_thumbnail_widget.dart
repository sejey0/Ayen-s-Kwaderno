import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_pdfviewer_platform_interface/pdfviewer_platform_interface.dart';
import '../theme/app_theme.dart';

/// Cache to avoid re-rendering PDF thumbnails repeatedly
final Map<String, Uint8List> _pdfThumbnailCache = {};

class DocumentThumbnailPreview extends StatefulWidget {
  final String? filePath;
  final String fileName;
  final Color backgroundColor;
  final Color accentColor;

  const DocumentThumbnailPreview({
    super.key,
    required this.filePath,
    required this.fileName,
    required this.backgroundColor,
    required this.accentColor,
  });

  @override
  State<DocumentThumbnailPreview> createState() =>
      _DocumentThumbnailPreviewState();
}

class _DocumentThumbnailPreviewState extends State<DocumentThumbnailPreview> {
  Uint8List? _pdfPageBytes;
  String? _resolvedFilePath;

  bool get _isImage {
    final path = (_resolvedFilePath ?? widget.filePath ?? widget.fileName).toLowerCase();
    return path.endsWith('.png') ||
        path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.webp') ||
        path.endsWith('.bmp');
  }

  @override
  void initState() {
    super.initState();
    _loadPdfThumbnail();
  }

  @override
  void didUpdateWidget(covariant DocumentThumbnailPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.fileName != widget.fileName) {
      _loadPdfThumbnail();
    }
  }

  Future<void> _loadPdfThumbnail() async {
    String? path = widget.filePath;

    // 1. If path is null or doesn't exist, auto-search saved_documents
    if (path == null || !File(path).existsSync()) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final savedDocsDir = Directory('${appDir.path}/saved_documents');
        if (savedDocsDir.existsSync()) {
          final candidates = [
            File('${savedDocsDir.path}/${widget.fileName}'),
            File('${savedDocsDir.path}/${widget.fileName}.pdf'),
            File('${savedDocsDir.path}/${widget.fileName}.png'),
            File('${savedDocsDir.path}/${widget.fileName}.jpg'),
          ];
          for (final f in candidates) {
            if (f.existsSync()) {
              path = f.path;
              break;
            }
          }
        }
      } catch (_) {}
    }

    if (path == null || !File(path).existsSync()) {
      if (mounted && _resolvedFilePath != null) {
        setState(() => _resolvedFilePath = null);
      }
      return;
    }

    if (mounted) {
      setState(() => _resolvedFilePath = path);
    }

    if (_isImage) return;

    if (_pdfThumbnailCache.containsKey(path)) {
      if (mounted) {
        setState(() {
          _pdfPageBytes = _pdfThumbnailCache[path];
        });
      }
      return;
    }

    try {
      final docId = 'thumb_${DateTime.now().millisecondsSinceEpoch}';
      final platform = PdfViewerPlatform.instance;
      await platform.loadPdfFromFile(path, docId);

      final bytes = await platform.getPage(1, 350, 480, docId);
      await platform.closeDocument(docId);

      if (bytes != null) {
        _pdfThumbnailCache[path] = bytes;
        if (mounted) {
          setState(() {
            _pdfPageBytes = bytes;
          });
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final path = _resolvedFilePath ?? widget.filePath;
    final fileExists = path != null && File(path).existsSync();

    // 1. Real Image Content Preview
    if (fileExists && _isImage) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _buildFallbackCover(),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.0),
                    Colors.black.withValues(alpha: 0.22),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // 2. Real PDF Page 1 Content Preview
    if (fileExists && _pdfPageBytes != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          RawImage(image: null),
          _PdfRawBytesPainter(rawRgbaBytes: _pdfPageBytes!),
        ],
      );
    }

    // 3. Fallback Aesthetic Cover Card with Realistic Document Layout
    return _buildFallbackCover();
  }

  Widget _buildFallbackCover() {
    final cleanName = widget.fileName
        .replaceAll('.pdf', '')
        .replaceAll('.png', '')
        .replaceAll('.jpg', '');

    return Container(
      color: const Color(0xFFFBFBFE),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Document Paper Header Pattern
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 36,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    widget.accentColor.withValues(alpha: 0.14),
                    widget.backgroundColor.withValues(alpha: 0.08),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),

          // Lined document sheet design
          Positioned.fill(
            top: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: widget.accentColor.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: 80,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: 110,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Center Document Type Emblem
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.accentColor.withValues(alpha: 0.25),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: 0.10),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isImage
                        ? CupertinoIcons.photo
                        : CupertinoIcons.doc_richtext,
                    size: 16,
                    color: widget.accentColor,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      cleanName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: widget.accentColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PdfRawBytesPainter extends StatefulWidget {
  final Uint8List rawRgbaBytes;

  const _PdfRawBytesPainter({required this.rawRgbaBytes});

  @override
  State<_PdfRawBytesPainter> createState() => _PdfRawBytesPainterState();
}

class _PdfRawBytesPainterState extends State<_PdfRawBytesPainter> {
  ui.Image? _uiImage;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  @override
  void didUpdateWidget(covariant _PdfRawBytesPainter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawRgbaBytes != widget.rawRgbaBytes) {
      _decodeImage();
    }
  }

  void _decodeImage() {
    ui.decodeImageFromPixels(
      widget.rawRgbaBytes,
      350,
      480,
      ui.PixelFormat.rgba8888,
      (image) {
        if (mounted) {
          setState(() {
            _uiImage = image;
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_uiImage != null) {
      return RawImage(
        image: _uiImage,
        fit: BoxFit.cover,
      );
    }
    return const Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppTheme.primaryPurple,
        ),
      ),
    );
  }
}
