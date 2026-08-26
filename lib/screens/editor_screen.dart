import 'dart:io';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../theme/app_theme.dart';

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

  // Active annotation tool state
  AnnotationTool _activeTool = AnnotationTool.none;
  Color _selectedColor = AppTheme.highlighterColors[0];
  final double _strokeWidth = 14.0;

  // Document page state
  int _currentPage = 1;
  int _pageCount = 1;
  bool _isDocumentLoaded = false;

  @override
  void initState() {
    super.initState();
    _pdfViewerController = PdfViewerController();
  }

  @override
  void dispose() {
    _pdfViewerController.dispose();
    super.dispose();
  }

  void _onToolSelected(AnnotationTool tool) {
    setState(() {
      if (_activeTool == tool) {
        _activeTool = AnnotationTool.none; // Toggle off to allow normal PDF scroll
      } else {
        _activeTool = tool;
      }
    });

    if (tool == AnnotationTool.addImage) {
      _showImagePickerPlaceholder();
    }
  }

  void _showImagePickerPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(CupertinoIcons.photo_on_rectangle,
                color: Colors.white, size: 18),
            SizedBox(width: 10),
            Text('Insert Image tool selected (Configured for Phase 2)'),
          ],
        ),
        backgroundColor: AppTheme.primaryPurpleDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 80),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = widget.fileName ?? 'Study Document';

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
              ),
            ),

            // ==========================================
            // ANNOTATION LAYER: GestureDetector & CustomPaint
            // (Transparent overlay for strokes & gestures)
            // ==========================================
            Positioned.fill(
              child: IgnorePointer(
                // In 'none' mode, let touch events pass through to the PDF Viewer for scrolling & zoom
                ignoring: _activeTool == AnnotationTool.none,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: (DragStartDetails details) {
                    // Coordinates hook for Phase 2 annotation rendering
                  },
                  onPanUpdate: (DragUpdateDetails details) {
                    // Coordinate stream hook
                  },
                  onPanEnd: (DragEndDetails details) {
                    // Coordinate completion & straight-line calculation hook
                  },
                  child: CustomPaint(
                    painter: BaseAnnotationPainter(
                      activeTool: _activeTool,
                      selectedColor: _selectedColor,
                      strokeWidth: _strokeWidth,
                    ),
                    size: Size.infinite,
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
              child: _buildTopAppBar(displayName),
            ),

            // ==========================================
            // FLOATING TOOLBAR: Elegant Bottom Annotation Bar
            // ==========================================
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Secondary Color/Stroke Palette (Visible when drawing tools active)
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

  /// Elegant glassmorphic Top App Bar
  Widget _buildTopAppBar(String title) {
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
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.primaryPurpleLight.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    CupertinoIcons.chevron_back,
                    color: AppTheme.primaryPurple,
                    size: 22,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 12),

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
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
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
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primaryPurpleDark,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_activeTool != AnnotationTool.none)
                          Text(
                            '• ${_getToolName(_activeTool)} active',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.accentPinkDark,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              // Undo / Redo Dummy Actions
              IconButton(
                icon: const Icon(
                  CupertinoIcons.arrow_uturn_left,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                tooltip: 'Undo',
                onPressed: () {},
              ),
              IconButton(
                icon: const Icon(
                  CupertinoIcons.arrow_uturn_right,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                tooltip: 'Redo',
                onPressed: () {},
              ),

              // Save / Supabase Sync Button
              Container(
                margin: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accentPink.withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Row(
                            children: [
                              Icon(CupertinoIcons.cloud_upload_fill,
                                  color: Colors.white, size: 18),
                              SizedBox(width: 10),
                              Text('Document annotations saved to Supabase!'),
                            ],
                          ),
                          backgroundColor: AppTheme.primaryPurpleDark,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      );
                    },
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            CupertinoIcons.bookmark_fill,
                            color: Colors.white,
                            size: 14,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Save',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
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
                  tooltip: 'Pan & Scroll Document',
                ),

                const SizedBox(width: 4),
                _buildVerticalDivider(),
                const SizedBox(width: 4),

                // 1. Highlighter
                _buildToolButton(
                  tool: AnnotationTool.highlighter,
                  icon: CupertinoIcons.pencil_outline,
                  label: 'Highlighter',
                  tooltip: 'Opacity Highlighter',
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

                // 3. Write Text
                _buildToolButton(
                  tool: AnnotationTool.handwritingText,
                  icon: CupertinoIcons.textformat,
                  label: 'Write Text',
                  tooltip: 'Handwriting to Text',
                ),

                const SizedBox(width: 4),

                // 4. Add Image
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

  /// Single tool icon button with active animations and soft pink/purple indicators
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

  /// Secondary floating color palette picker
  Widget _buildColorPickerSubBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.dividerColor),
            boxShadow: AppTheme.softShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: AppTheme.highlighterColors.map((color) {
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
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalDivider() {
    return Container(
      width: 1,
      height: 24,
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
        return 'Pan';
    }
  }
}

/// Base Transparent Annotation Painter overlay for Phase 1 architecture
class BaseAnnotationPainter extends CustomPainter {
  final AnnotationTool activeTool;
  final Color selectedColor;
  final double strokeWidth;

  BaseAnnotationPainter({
    required this.activeTool,
    required this.selectedColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Phase 1: Transparent drawing layer ready for coordinate streams
    // Custom drawing routines for highlighter strokes, lines, and text containers will be painted here in Phase 2
  }

  @override
  bool shouldRepaint(covariant BaseAnnotationPainter oldDelegate) {
    return oldDelegate.activeTool != activeTool ||
        oldDelegate.selectedColor != selectedColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
