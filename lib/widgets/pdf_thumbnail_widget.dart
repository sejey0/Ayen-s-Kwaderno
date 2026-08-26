import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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

  bool get _isImage {
    final path = widget.filePath?.toLowerCase() ?? '';
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
    if (oldWidget.filePath != widget.filePath) {
      _loadPdfThumbnail();
    }
  }

  Future<void> _loadPdfThumbnail() async {
    final path = widget.filePath;
    if (path == null || !File(path).existsSync() || _isImage) return;

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
    final path = widget.filePath;
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
          // Subtle gradient overlay at bottom for readability
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.0),
                    Colors.black.withValues(alpha: 0.25),
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
          RawImage(
            image: null, // Will render via CustomPainter below
          ),
          _PdfRawBytesPainter(rawRgbaBytes: _pdfPageBytes!),
        ],
      );
    }

    // 3. Fallback Aesthetic Cover Card
    return _buildFallbackCover();
  }

  Widget _buildFallbackCover() {
    return Container(
      color: widget.backgroundColor,
      padding: const EdgeInsets.all(12),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.accentColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isImage
                    ? CupertinoIcons.photo_fill
                    : CupertinoIcons.doc_text_fill,
                size: 32,
                color: widget.accentColor.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
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
