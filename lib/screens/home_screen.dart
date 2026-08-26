import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/document_item_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/handwriting_canvas.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isPickingDocument = false;
  bool _isLoadingCloudDocuments = false;
  String _selectedFilter = 'All Documents';

  // Persistent dynamic document list
  List<DocumentItem> _documents = [];

  // Palette generator for dynamic notebook cover aesthetics
  static const List<Map<String, Color>> _coverPalettes = [
    {
      'color': Color(0xFFE9E4FC),
      'accent': AppTheme.primaryPurple,
    },
    {
      'color': Color(0xFFFFEEF3),
      'accent': AppTheme.accentPink,
    },
    {
      'color': Color(0xFFE6F4FE),
      'accent': Color(0xFF5B9BF6),
    },
    {
      'color': Color(0xFFE8F8F0),
      'accent': Color(0xFF34D399),
    },
    {
      'color': Color(0xFFFEF3C7),
      'accent': Color(0xFFF59E0B),
    },
    {
      'color': Color(0xFFF3E8FF),
      'accent': Color(0xFF8B5CF6),
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadInitialDocuments();
  }

  /// Initial load: loads local cache instantly, then syncs with Supabase in background
  Future<void> _loadInitialDocuments() async {
    // 1. Instant local load
    final localDocs = await DocumentStorageService.loadSavedDocuments();
    if (mounted) {
      setState(() {
        _documents = localDocs;
      });
    }

    // 2. Background Supabase sync
    await _syncWithCloud();
  }

  /// Fetches saved document annotations from Supabase and merges with local list
  Future<void> _syncWithCloud() async {
    try {
      setState(() => _isLoadingCloudDocuments = true);

      final client = Supabase.instance.client;
      final response = await client
          .from('document_annotations')
          .select('document_name, updated_at, strokes_data, texts_data, images_data')
          .order('updated_at', ascending: false);

      if (!mounted) return;

      final localDocs = await DocumentStorageService.loadSavedDocuments();
      final Map<String, DocumentItem> docMap = {
        for (var doc in localDocs) doc.fileName: doc
      };

      for (int i = 0; i < response.length; i++) {
        final row = response[i];
        final docName = row['document_name'] as String? ?? 'Untitled Document';
        final updatedAtStr = row['updated_at'] as String?;
        final strokes = row['strokes_data'] as List<dynamic>? ?? [];
        final texts = row['texts_data'] as List<dynamic>? ?? [];
        final images = row['images_data'] as List<dynamic>? ?? [];
        final totalAnnotations = strokes.length + texts.length + images.length;

        DateTime cloudUpdatedAt = DateTime.now();
        if (updatedAtStr != null) {
          cloudUpdatedAt = DateTime.tryParse(updatedAtStr)?.toLocal() ?? DateTime.now();
        }

        if (docMap.containsKey(docName)) {
          // Update existing local document with cloud state
          final existing = docMap[docName]!;
          docMap[docName] = existing.copyWith(
            annotationsCount: totalAnnotations,
            isCloudSynced: true,
            lastOpenedAt: cloudUpdatedAt.isAfter(existing.lastOpenedAt)
                ? cloudUpdatedAt
                : existing.lastOpenedAt,
          );
        } else {
          // Add new cloud-synced document
          docMap[docName] = DocumentItem(
            fileName: docName,
            filePath: null, // Cloud-only until user opens file locally
            lastOpenedAt: cloudUpdatedAt,
            annotationsCount: totalAnnotations,
            isCloudSynced: true,
            paletteIndex: i % _coverPalettes.length,
          );
        }

        // Persist merged document
        await DocumentStorageService.saveOrUpdateDocument(docMap[docName]!);
      }

      final mergedList = docMap.values.toList()
        ..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));

      setState(() {
        _documents = mergedList;
        _isLoadingCloudDocuments = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingCloudDocuments = false);
      debugPrint('Cloud sync notice (offline or unconfigured): $e');
    }
  }

  /// Handles picking a PDF document using FilePicker, saving to persistence, and opening Editor
  Future<void> _pickAndOpenDocument() async {
    try {
      setState(() => _isPickingDocument = true);

      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (!mounted) return;
      setState(() => _isPickingDocument = false);

      if (picked != null && picked.path != null) {
        final filePath = picked.path!;
        final fileName = picked.name;

        // Persist document to local storage
        final newDoc = DocumentItem(
          fileName: fileName,
          filePath: filePath,
          lastOpenedAt: DateTime.now(),
          annotationsCount: 0,
          paletteIndex: _documents.length % _coverPalettes.length,
          isCloudSynced: false,
        );

        await DocumentStorageService.saveOrUpdateDocument(newDoc);

        // Update in-memory state
        setState(() {
          _documents.removeWhere((d) => d.fileName == fileName);
          _documents.insert(0, newDoc);
        });

        if (!mounted) return;

        // Smooth PageRoute transition into Editor
        await Navigator.of(context).push(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                EditorScreen(
              pdfPath: filePath,
              fileName: fileName,
            ),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
              const begin = Offset(0.0, 0.05);
              const end = Offset.zero;
              const curve = Curves.easeOutCubic;

              final tween =
                  Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
              final fadeTween = Tween<double>(begin: 0.0, end: 1.0)
                  .chain(CurveTween(curve: curve));

              return SlideTransition(
                position: animation.drive(tween),
                child: FadeTransition(
                  opacity: animation.drive(fadeTween),
                  child: child,
                ),
              );
            },
            transitionDuration: const Duration(milliseconds: 300),
          ),
        );

        // Refresh list upon returning from editor
        _loadInitialDocuments();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPickingDocument = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Unable to open document: $e'),
              ),
            ],
          ),
          backgroundColor: AppTheme.textPrimary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  /// Launches Google ML Kit Handwriting Recognition from Home Screen
  Future<void> _launchHandwritingToText() async {
    final recognizedText = await HandwritingCanvasDialog.show(context);

    if (!mounted) return;

    if (recognizedText != null && recognizedText.trim().isNotEmpty) {
      _showRecognizedResultDialog(recognizedText.trim());
    }
  }

  /// Displays the recognized text result modal with Copy and Share actions
  void _showRecognizedResultDialog(String text) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.sparkles, color: AppTheme.primaryPurple, size: 18),
            SizedBox(width: 6),
            Text('Recognized Text'),
          ],
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 14.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.dividerColor),
                ),
                child: SelectableText(
                  text,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.textPrimary,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Handwriting converted via Google ML Kit Digital Ink.',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Close'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Row(
                    children: [
                      Icon(CupertinoIcons.doc_on_clipboard_fill,
                          color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text('Copied text to clipboard! 📋'),
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
            },
            child: const Text('Copy Text'),
          ),
        ],
      ),
    );
  }

  /// Opens a saved document card
  Future<void> _openDocument(DocumentItem doc) async {
    final path = doc.filePath;

    if (path != null && File(path).existsSync()) {
      // Update last opened time
      final updated = doc.copyWith(lastOpenedAt: DateTime.now());
      await DocumentStorageService.saveOrUpdateDocument(updated);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => EditorScreen(
            pdfPath: path,
            fileName: doc.fileName,
          ),
        ),
      );

      _loadInitialDocuments();
    } else {
      // File path missing/moved: prompt to select PDF file from device
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(CupertinoIcons.folder_badge_plus,
                  color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Select "${doc.fileName}" from device to load and sync annotations.',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Select PDF',
            textColor: AppTheme.accentPinkLight,
            onPressed: () async {
              final picked = await FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: ['pdf'],
              );
              if (picked != null && picked.path != null) {
                final selectedPath = picked.path!;
                final updatedDoc = doc.copyWith(
                  filePath: selectedPath,
                  lastOpenedAt: DateTime.now(),
                );
                await DocumentStorageService.saveOrUpdateDocument(updatedDoc);

                if (!mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => EditorScreen(
                      pdfPath: selectedPath,
                      fileName: doc.fileName,
                    ),
                  ),
                );
                _loadInitialDocuments();
              }
            },
          ),
          backgroundColor: AppTheme.primaryPurpleDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// Deletes a document from the recent list with confirmation
  void _confirmDeleteDocument(DocumentItem doc) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Remove from Recent?'),
        content: Text(
          'Do you want to remove "${doc.fileName}" from your recent documents list? Cloud annotations will remain preserved.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Remove'),
            onPressed: () async {
              Navigator.pop(context);
              await DocumentStorageService.deleteDocument(doc.fileName);
              setState(() {
                _documents.removeWhere((d) => d.fileName == doc.fileName);
              });
            },
          ),
        ],
      ),
    );
  }

  /// Returns filtered documents according to selected category chip
  List<DocumentItem> get _filteredDocuments {
    if (_selectedFilter == 'Recently Opened') {
      return _documents
          .where((d) => d.filePath != null && File(d.filePath!).existsSync())
          .toList();
    } else if (_selectedFilter == 'Cloud Synced') {
      return _documents.where((d) => d.isCloudSynced).toList();
    }
    return _documents;
  }

  @override
  Widget build(BuildContext context) {
    final displayDocs = _filteredDocuments;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppTheme.primaryPurple,
          backgroundColor: AppTheme.surfaceWhite,
          onRefresh: _syncWithCloud,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              // Top App Bar with Greeting & Profile
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20.0, vertical: 16.0),
                  child: _buildHeader(),
                ),
              ),

              // Hero Quick Action Banner (Open PDF & Handwriting to Text)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: _buildUploadHeroCard(),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 28)),

              // Filter Tabs (All, Recently Opened, Cloud Synced)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: _buildFilterChips(),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 20)),

              // Section Header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            _selectedFilter == 'All Documents'
                                ? 'My Study Notebooks (${displayDocs.length})'
                                : '$_selectedFilter (${displayDocs.length})',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                              letterSpacing: -0.3,
                            ),
                          ),
                          if (_isLoadingCloudDocuments) ...[
                            const SizedBox(width: 10),
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.primaryPurple,
                              ),
                            ),
                          ],
                        ],
                      ),
                      IconButton(
                        icon: const Icon(
                          CupertinoIcons.arrow_clockwise,
                          size: 17,
                          color: AppTheme.primaryPurple,
                        ),
                        tooltip: 'Sync with Cloud',
                        onPressed:
                            _isLoadingCloudDocuments ? null : _syncWithCloud,
                      ),
                    ],
                  ),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 10)),

              // Grid or Empty State
              if (displayDocs.isEmpty && !_isLoadingCloudDocuments)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 8.0),
                    child: _buildEmptyState(),
                  ),
                )
              else if (displayDocs.isEmpty && _isLoadingCloudDocuments)
                SliverToBoxAdapter(
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40.0),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: AppTheme.primaryPurple,
                            strokeWidth: 2.5,
                          ),
                          SizedBox(height: 14),
                          Text(
                            'Loading notebooks...',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20.0, vertical: 4.0),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                      childAspectRatio: 0.78,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final doc = displayDocs[index];
                        return _buildNotebookCard(doc);
                      },
                      childCount: displayDocs.length,
                    ),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 90)),
            ],
          ),
        ),
      ),

      // Floating Action Button for Quick Upload
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isPickingDocument ? null : _pickAndOpenDocument,
        backgroundColor: AppTheme.accentPink,
        foregroundColor: Colors.white,
        elevation: 4,
        icon: _isPickingDocument
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(CupertinoIcons.add, size: 20),
        label: const Text(
          'New Document',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }

  /// Clean, GoodNotes-style Empty State Placeholder
  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 36.0),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.dividerColor),
        boxShadow: AppTheme.softShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: AppTheme.primaryPurpleLight,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryPurple.withValues(alpha: 0.15),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                CupertinoIcons.doc_text_search,
                color: AppTheme.primaryPurple,
                size: 34,
              ),
            ),
          ),
          const SizedBox(height: 18),

          Text(
            _selectedFilter == 'All Documents'
                ? 'No Study Notebooks Yet'
                : 'No $_selectedFilter Found',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),

          Text(
            _selectedFilter == 'All Documents'
                ? 'Import your PDF slides, reviewers, or textbooks to start highlighting and syncing to the cloud.'
                : 'Tap "Open PDF Document" below to import your study material into this section.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 22),

          // Action button inside empty state
          ElevatedButton.icon(
            onPressed: _isPickingDocument ? null : _pickAndOpenDocument,
            icon: const Icon(CupertinoIcons.arrow_up_doc_fill, size: 16),
            label: const Text(
              'Open PDF Document',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Top Profile & Greeting Row
  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            // Soft Avatar / Monogram with glow ring
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [AppTheme.primaryPurple, AppTheme.accentPink],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryPurple.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  'A',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      "Ayen's Kwaderno",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.accentPinkLight,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'PRO',
                        style: TextStyle(
                          color: AppTheme.accentPinkDark,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                const Text(
                  'Let’s organize your study session ✨',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        // Cloud Sync Status / Refresh Button
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceWhite,
            shape: BoxShape.circle,
            boxShadow: AppTheme.softShadow,
            border: Border.all(color: AppTheme.dividerColor),
          ),
          child: IconButton(
            icon: const Icon(
              CupertinoIcons.cloud_upload,
              color: AppTheme.primaryPurple,
              size: 20,
            ),
            tooltip: 'Sync with Supabase',
            onPressed: () {
              _syncWithCloud();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Row(
                    children: [
                      Icon(Icons.check_circle_outline_rounded,
                          color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text('Cloud Sync refreshed from Supabase ✨'),
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
            },
          ),
        ),
      ],
    );
  }

  /// Big Action Hero Card (Open PDF & Handwriting to Text)
  Widget _buildUploadHeroCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTheme.softShadow,
        border: Border.all(
          color: AppTheme.primaryPurpleLight.withValues(alpha: 0.8),
          width: 1.5,
        ),
      ),
      child: Stack(
        children: [
          // Decorative background circles
          Positioned(
            right: -25,
            top: -25,
            child: Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.primaryPurpleLight.withValues(alpha: 0.4),
              ),
            ),
          ),
          Positioned(
            right: 40,
            bottom: -30,
            child: Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.accentPinkLight.withValues(alpha: 0.4),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Icon Container
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFEFEBFF), Color(0xFFFFEEF3)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: Icon(
                          CupertinoIcons.doc_text_viewfinder,
                          color: AppTheme.primaryPurple,
                          size: 26,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quick Study Actions',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Import PDF reviewers or convert digital ink handwriting into clean text.',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppTheme.textSecondary,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Action Buttons Row: [ Open PDF ] & [ Handwriting to Text ]
                Row(
                  children: [
                    // 1. Open PDF Document Button
                    Expanded(
                      flex: 6,
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed:
                              _isPickingDocument ? null : _pickAndOpenDocument,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Ink(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  AppTheme.primaryPurple,
                                  Color(0xFF9E8AF0),
                                  AppTheme.accentPink,
                                ],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primaryPurple
                                      .withValues(alpha: 0.35),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Container(
                              alignment: Alignment.center,
                              child: _isPickingDocument
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(CupertinoIcons.folder_badge_plus,
                                            size: 17, color: Colors.white),
                                        SizedBox(width: 7),
                                        Text(
                                          'Open PDF',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.1,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 10),

                    // 2. Handwriting to Text Button
                    Expanded(
                      flex: 5,
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: _launchHandwritingToText,
                          style: OutlinedButton.styleFrom(
                            backgroundColor: AppTheme.primaryPurpleLight
                                .withValues(alpha: 0.6),
                            side: const BorderSide(
                              color: AppTheme.primaryPurple,
                              width: 1.4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                CupertinoIcons.textformat,
                                size: 17,
                                color: AppTheme.primaryPurpleDark,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Handwriting',
                                style: TextStyle(
                                  color: AppTheme.primaryPurpleDark,
                                  fontSize: 13,
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Filter tabs (All Documents, Recently Opened, Cloud Synced)
  Widget _buildFilterChips() {
    final filters = ['All Documents', 'Recently Opened', 'Cloud Synced'];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: filters.map((filter) {
          final isSelected = _selectedFilter == filter;
          return Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: GestureDetector(
              onTap: () => setState(() => _selectedFilter = filter),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 9.0),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.primaryPurple
                      : AppTheme.surfaceWhite,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? AppTheme.primaryPurple
                        : AppTheme.dividerColor,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color:
                                AppTheme.primaryPurple.withValues(alpha: 0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  filter,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? Colors.white : AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Study Notebook Card
  Widget _buildNotebookCard(DocumentItem doc) {
    final palette = _coverPalettes[doc.paletteIndex % _coverPalettes.length];
    final color = palette['color']!;
    final accent = palette['accent']!;

    return GestureDetector(
      onTap: () => _openDocument(doc),
      onLongPress: () => _confirmDeleteDocument(doc),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surfaceWhite,
          borderRadius: BorderRadius.circular(20),
          boxShadow: AppTheme.softShadow,
          border: Border.all(color: AppTheme.dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Notebook Cover Preview
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(19),
                        topRight: Radius.circular(19),
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        CupertinoIcons.doc_text_fill,
                        size: 44,
                        color: accent.withValues(alpha: 0.7),
                      ),
                    ),
                  ),

                  // Left Spine / Wire Binding Effect
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.25),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(19),
                        ),
                      ),
                    ),
                  ),

                  // Cloud Synced Badge
                  if (doc.isCloudSynced)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.cloud_upload_fill,
                              size: 11,
                              color: Color(0xFF10B981),
                            ),
                            SizedBox(width: 3),
                            Text(
                              'Synced',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF065F46),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Document Details
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doc.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${doc.annotationsCount} mark${doc.annotationsCount == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryPurple,
                        ),
                      ),
                      Text(
                        _formatTimestamp(doc.lastOpenedAt),
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.month}/${dt.day}';
  }
}
