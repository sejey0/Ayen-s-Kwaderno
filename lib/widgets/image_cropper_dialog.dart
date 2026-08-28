import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../theme/app_theme.dart';

/// Interactive In-App Image Cropper Modal Dialog
class ImageCropperDialog extends StatefulWidget {
  final String imagePath;

  const ImageCropperDialog({
    super.key,
    required this.imagePath,
  });

  /// Static helper to open the cropper dialog and return cropped file path
  static Future<String?> show(BuildContext context, String imagePath) {
    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Crop Image',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) =>
          ImageCropperDialog(imagePath: imagePath),
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<ImageCropperDialog> createState() => _ImageCropperDialogState();
}

enum _ActiveDragHandle { none, center, topLeft, topRight, bottomLeft, bottomRight }

class _ImageCropperDialogState extends State<ImageCropperDialog> {
  ui.Image? _decodedImage;
  bool _isLoading = true;
  bool _isProcessing = false;

  // Layout & Crop Geometry
  Rect? _imageFittedRect;
  Rect _cropRect = Rect.zero;
  _ActiveDragHandle _activeHandle = _ActiveDragHandle.none;

  // Aspect ratio presets (null = Freeform)
  double? _targetAspectRatio;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _decodedImage = frame.image;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load image for cropping: $e')),
      );
      Navigator.of(context).pop();
    }
  }

  void _calculateInitialCropRect(Size availableSize) {
    if (_decodedImage == null) return;

    final imgW = _decodedImage!.width.toDouble();
    final imgH = _decodedImage!.height.toDouble();

    // Compute fitted image rect with padding inside container
    final fittedSizes = applyBoxFit(
      BoxFit.contain,
      Size(imgW, imgH),
      availableSize,
    );

    final dx = (availableSize.width - fittedSizes.destination.width) / 2;
    final dy = (availableSize.height - fittedSizes.destination.height) / 2;

    _imageFittedRect = Rect.fromLTWH(
      dx,
      dy,
      fittedSizes.destination.width,
      fittedSizes.destination.height,
    );

    if (_cropRect == Rect.zero) {
      // Inset crop rect by 6% initially for great UX
      final insetW = _imageFittedRect!.width * 0.04;
      final insetH = _imageFittedRect!.height * 0.04;
      _cropRect = _imageFittedRect!.deflate(insetW < insetH ? insetW : insetH);
    }
  }

  void _setAspectRatio(double? ratio) {
    HapticFeedback.selectionClick();
    setState(() {
      _targetAspectRatio = ratio;
      if (_imageFittedRect != null) {
        if (ratio == null) {
          // Freeform: Reset to full image
          _cropRect = _imageFittedRect!;
        } else {
          // Fit target aspect ratio inside _imageFittedRect
          double w = _imageFittedRect!.width;
          double h = w / ratio;
          if (h > _imageFittedRect!.height) {
            h = _imageFittedRect!.height;
            w = h * ratio;
          }
          final left =
              _imageFittedRect!.left + (_imageFittedRect!.width - w) / 2;
          final top =
              _imageFittedRect!.top + (_imageFittedRect!.height - h) / 2;
          _cropRect = Rect.fromLTWH(left, top, w, h);
        }
      }
    });
  }

  _ActiveDragHandle _detectHandle(Offset localPos) {
    const double touchRadius = 28.0;

    if ((localPos - _cropRect.topLeft).distance <= touchRadius) {
      return _ActiveDragHandle.topLeft;
    }
    if ((localPos - _cropRect.topRight).distance <= touchRadius) {
      return _ActiveDragHandle.topRight;
    }
    if ((localPos - _cropRect.bottomLeft).distance <= touchRadius) {
      return _ActiveDragHandle.bottomLeft;
    }
    if ((localPos - _cropRect.bottomRight).distance <= touchRadius) {
      return _ActiveDragHandle.bottomRight;
    }
    if (_cropRect.contains(localPos)) {
      return _ActiveDragHandle.center;
    }

    return _ActiveDragHandle.none;
  }

  void _onPanStart(DragStartDetails details) {
    final handle = _detectHandle(details.localPosition);
    setState(() {
      _activeHandle = handle;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_imageFittedRect == null || _activeHandle == _ActiveDragHandle.none) {
      return;
    }

    final b = _imageFittedRect!;
    final delta = details.delta;

    double left = _cropRect.left;
    double top = _cropRect.top;
    double right = _cropRect.right;
    double bottom = _cropRect.bottom;

    const double minDimension = 40.0;

    switch (_activeHandle) {
      case _ActiveDragHandle.center:
        final newLeft = (left + delta.dx).clamp(b.left, b.right - _cropRect.width);
        final newTop = (top + delta.dy).clamp(b.top, b.bottom - _cropRect.height);
        _cropRect = Rect.fromLTWH(newLeft, newTop, _cropRect.width, _cropRect.height);
        break;

      case _ActiveDragHandle.topLeft:
        left = (left + delta.dx).clamp(b.left, right - minDimension);
        top = (top + delta.dy).clamp(b.top, bottom - minDimension);
        if (_targetAspectRatio != null) {
          final w = right - left;
          top = (bottom - (w / _targetAspectRatio!)).clamp(b.top, bottom - minDimension);
        }
        _cropRect = Rect.fromLTRB(left, top, right, bottom);
        break;

      case _ActiveDragHandle.topRight:
        right = (right + delta.dx).clamp(left + minDimension, b.right);
        top = (top + delta.dy).clamp(b.top, bottom - minDimension);
        if (_targetAspectRatio != null) {
          final w = right - left;
          top = (bottom - (w / _targetAspectRatio!)).clamp(b.top, bottom - minDimension);
        }
        _cropRect = Rect.fromLTRB(left, top, right, bottom);
        break;

      case _ActiveDragHandle.bottomLeft:
        left = (left + delta.dx).clamp(b.left, right - minDimension);
        bottom = (bottom + delta.dy).clamp(top + minDimension, b.bottom);
        if (_targetAspectRatio != null) {
          final w = right - left;
          bottom = (top + (w / _targetAspectRatio!)).clamp(top + minDimension, b.bottom);
        }
        _cropRect = Rect.fromLTRB(left, top, right, bottom);
        break;

      case _ActiveDragHandle.bottomRight:
        right = (right + delta.dx).clamp(left + minDimension, b.right);
        bottom = (bottom + delta.dy).clamp(top + minDimension, b.bottom);
        if (_targetAspectRatio != null) {
          final w = right - left;
          bottom = (top + (w / _targetAspectRatio!)).clamp(top + minDimension, b.bottom);
        }
        _cropRect = Rect.fromLTRB(left, top, right, bottom);
        break;

      case _ActiveDragHandle.none:
        break;
    }

    setState(() {});
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() => _activeHandle = _ActiveDragHandle.none);
  }

  Future<void> _applyCrop() async {
    if (_decodedImage == null || _imageFittedRect == null || _isProcessing) {
      return;
    }

    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    try {
      final img = _decodedImage!;
      final origW = img.width.toDouble();
      final origH = img.height.toDouble();

      final normLeft =
          ((_cropRect.left - _imageFittedRect!.left) / _imageFittedRect!.width)
              .clamp(0.0, 1.0);
      final normTop =
          ((_cropRect.top - _imageFittedRect!.top) / _imageFittedRect!.height)
              .clamp(0.0, 1.0);
      final normW = (_cropRect.width / _imageFittedRect!.width).clamp(0.01, 1.0);
      final normH = (_cropRect.height / _imageFittedRect!.height).clamp(0.01, 1.0);

      final srcX = (normLeft * origW).clamp(0.0, origW - 1);
      final srcY = (normTop * origH).clamp(0.0, origH - 1);
      final srcW = (normW * origW).clamp(1.0, origW - srcX);
      final srcH = (normH * origH).clamp(1.0, origH - srcY);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, srcW, srcH));

      canvas.drawImageRect(
        img,
        Rect.fromLTWH(srcX, srcY, srcW, srcH),
        Rect.fromLTWH(0, 0, srcW, srcH),
        Paint()..filterQuality = FilterQuality.high,
      );

      final picture = recorder.endRecording();
      final croppedUiImage =
          await picture.toImage(srcW.toInt(), srcH.toInt());
      final byteData =
          await croppedUiImage.toByteData(format: ui.ImageByteFormat.png);

      if (byteData == null) {
        throw Exception('Failed to encode cropped image');
      }

      final appDir = await getApplicationDocumentsDirectory();
      final croppedFile = File(
          '${appDir.path}/crop_${DateTime.now().millisecondsSinceEpoch}.png');
      await croppedFile.writeAsBytes(byteData.buffer.asUint8List());

      if (!mounted) return;
      Navigator.of(context).pop(croppedFile.path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to crop image: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            // Top Navigation & Action Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Cancel Button
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    icon: const Icon(CupertinoIcons.xmark, size: 18),
                    label: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),

                  // Title Badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryPurple.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppTheme.primaryPurple.withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.crop,
                          size: 14,
                          color: AppTheme.accentPink,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Crop Image',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Done / Apply Button
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    onPressed: _isProcessing ? null : _applyCrop,
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryPurple
                                .withValues(alpha: 0.4),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: _isProcessing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.checkmark_alt,
                                      size: 16, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text(
                                    'Apply',
                                    style: TextStyle(
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
                ],
              ),
            ),

            // Middle Interactive Crop Canvas
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppTheme.primaryPurple,
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final availableSize =
                            Size(constraints.maxWidth, constraints.maxHeight);

                        if (_imageFittedRect == null) {
                          _calculateInitialCropRect(availableSize);
                        }

                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: _onPanStart,
                          onPanUpdate: _onPanUpdate,
                          onPanEnd: _onPanEnd,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // 1. Raw Rendered Image Base
                              if (_decodedImage != null &&
                                  _imageFittedRect != null)
                                Positioned.fromRect(
                                  rect: _imageFittedRect!,
                                  child: RawImage(
                                    image: _decodedImage,
                                    fit: BoxFit.contain,
                                  ),
                                ),

                              // 2. Translucent Mask & Interactive Crop Overlay
                              if (_imageFittedRect != null)
                                CustomPaint(
                                  size: availableSize,
                                  painter: _CropOverlayPainter(
                                    fittedRect: _imageFittedRect!,
                                    cropRect: _cropRect,
                                    activeHandle: _activeHandle,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),

            // Bottom Aspect Ratio Toolbar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildAspectPresetPill(
                      label: 'Freeform',
                      icon: CupertinoIcons.rectangle_grid_1x2,
                      ratio: null,
                    ),
                    const SizedBox(width: 8),
                    _buildAspectPresetPill(
                      label: '1:1 Square',
                      icon: CupertinoIcons.square,
                      ratio: 1.0,
                    ),
                    const SizedBox(width: 8),
                    _buildAspectPresetPill(
                      label: '4:3 Standard',
                      icon: CupertinoIcons.rectangle,
                      ratio: 4.0 / 3.0,
                    ),
                    const SizedBox(width: 8),
                    _buildAspectPresetPill(
                      label: '16:9 Widescreen',
                      icon: CupertinoIcons.tv,
                      ratio: 16.0 / 9.0,
                    ),
                    const SizedBox(width: 8),
                    _buildAspectPresetPill(
                      label: '3:4 Portrait',
                      icon: CupertinoIcons.device_phone_portrait,
                      ratio: 3.0 / 4.0,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAspectPresetPill({
    required String label,
    required IconData icon,
    required double? ratio,
  }) {
    final isSelected = _targetAspectRatio == ratio;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _setAspectRatio(ratio),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.primaryPurple
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? AppTheme.accentPink
                  : Colors.white.withValues(alpha: 0.12),
              width: isSelected ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected ? Colors.white : Colors.white70,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? Colors.white : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Custom Painter drawing the darkened crop shroud, rule-of-thirds grid, and 4 corner handles
class _CropOverlayPainter extends CustomPainter {
  final Rect fittedRect;
  final Rect cropRect;
  final _ActiveDragHandle activeHandle;

  _CropOverlayPainter({
    required this.fittedRect,
    required this.cropRect,
    required this.activeHandle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw darkened backdrop outside cropRect
    final bgPath = Path()..addRect(fittedRect);
    final cropPath = Path()..addRect(cropRect);
    final shroudPath = Path.combine(PathOperation.difference, bgPath, cropPath);

    final shroudPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.65)
      ..style = PaintingStyle.fill;

    canvas.drawPath(shroudPath, shroudPaint);

    // 2. Draw border around crop rectangle
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    canvas.drawRect(cropRect, borderPaint);

    // 3. Draw Rule of Thirds Grid lines
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;

    final stepX = cropRect.width / 3;
    final stepY = cropRect.height / 3;

    // Vertical grid lines
    canvas.drawLine(
      Offset(cropRect.left + stepX, cropRect.top),
      Offset(cropRect.left + stepX, cropRect.bottom),
      gridPaint,
    );
    canvas.drawLine(
      Offset(cropRect.left + stepX * 2, cropRect.top),
      Offset(cropRect.left + stepX * 2, cropRect.bottom),
      gridPaint,
    );

    // Horizontal grid lines
    canvas.drawLine(
      Offset(cropRect.left, cropRect.top + stepY),
      Offset(cropRect.right, cropRect.top + stepY),
      gridPaint,
    );
    canvas.drawLine(
      Offset(cropRect.left, cropRect.top + stepY * 2),
      Offset(cropRect.right, cropRect.top + stepY * 2),
      gridPaint,
    );

    // 4. Draw 4 Corner Handles
    _drawCornerHandle(canvas, cropRect.topLeft, true, true);
    _drawCornerHandle(canvas, cropRect.topRight, true, false);
    _drawCornerHandle(canvas, cropRect.bottomLeft, false, true);
    _drawCornerHandle(canvas, cropRect.bottomRight, false, false);
  }

  void _drawCornerHandle(
      Canvas canvas, Offset center, bool isTop, bool isLeft) {
    const double length = 18.0;
    const double thickness = 3.5;

    final handlePaint = Paint()
      ..color = AppTheme.primaryPurple
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;

    final outlinePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness + 1.8
      ..strokeCap = StrokeCap.round;

    final horizontalEnd =
        Offset(center.dx + (isLeft ? length : -length), center.dy);
    final verticalEnd =
        Offset(center.dx, center.dy + (isTop ? length : -length));

    // Outer white outline for high contrast
    canvas.drawLine(center, horizontalEnd, outlinePaint);
    canvas.drawLine(center, verticalEnd, outlinePaint);

    // Inner purple core
    canvas.drawLine(center, horizontalEnd, handlePaint);
    canvas.drawLine(center, verticalEnd, handlePaint);
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect ||
        oldDelegate.activeHandle != activeHandle ||
        oldDelegate.fittedRect != fittedRect;
  }
}
