import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/document_item_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';
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

      final pickedFile = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (!mounted) return;
      setState(() => _isPickingDocument = false);

      if (pickedFile != null && pickedFile.path != null) {
        final filePath = pickedFile.path!;
        final fileName = pickedFile.name;

        // Persist document immediately
        final newDoc = DocumentItem(
          fileName: fileName,
          filePath: filePath,
          lastOpenedAt: DateTime.now(),
          paletteIndex: _documents.length % _coverPalettes.length,
        );

        await DocumentStorageService.saveOrUpdateDocument(newDoc);

        // Update in-memory state
        setState(() {
          _documents.removeWhere((d) => d.fileName == fileName);
          _documents.insert(0, newDoc);
        });

        // Navigate to EditorScreen
        if (!mounted) return;
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
              final fadeTween = Tween<double>(begin: 0.0, end: 1.0);

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
                final updatedDoc = doc.copyWith(
                  filePath: picked.path,
                  lastOpenedAt: DateTime.now(),
                );
                await DocumentStorageService.saveOrUpdateDocument(updatedDoc);

                if (!mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => EditorScreen(
                      pdfPath: picked.path!,
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

              // Hero Upload Dropzone Banner
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
                        onPressed: _isLoadingCloudDocuments ? null : _syncWithCloud,
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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40.0),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: AppTheme.primaryPurple,
                            strokeWidth: 2.5,
                          ),
                          const SizedBox(height: 14),
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
        border: Border.all(
          color: AppTheme.dividerColor,
          width: 1.5,
        ),
        boxShadow: AppTheme.softShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pastel illustration ring
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFEFEBFF), Color(0xFFFFEEF3)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryPurple.withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
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
                ? 'Import your PDF slides, reviewers, or textbooks to start highlighting, handwriting notes, and syncing to the cloud.'
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

  /// Big Upload / Open Document Hero Card
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
            padding: const EdgeInsets.all(22.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Icon Container
                    Container(
                      width: 52,
                      height: 52,
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
                          size: 28,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Annotate Document',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Import any PDF slide, textbook, or reviewer to highlight and annotate.',
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
                const SizedBox(height: 18),

                // Action Upload Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isPickingDocument ? null : _pickAndOpenDocument,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
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
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color:
                                AppTheme.primaryPurple.withValues(alpha: 0.35),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Container(
                        alignment: Alignment.center,
                        child: _isPickingDocument
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    CupertinoIcons.arrow_up_doc_fill,
                                    size: 19,
                                    color: Colors.white,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    'Upload / Open PDF Document',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
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
        ],
      ),
    );
  }

  /// Horizontal category filter tabs
  Widget _buildFilterChips() {
    final filters = ['All Documents', 'Recently Opened', 'Cloud Synced'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: filters.map((filter) {
          final isSelected = _selectedFilter == filter;
          return Padding(
            padding: const EdgeInsets.only(right: 10.0),
            child: InkWell(
              onTap: () => setState(() => _selectedFilter = filter),
              borderRadius: BorderRadius.circular(20),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

  /// Single Notebook Item Card (GoodNotes Stationery Style)
  Widget _buildNotebookCard(DocumentItem doc) {
    final palette = _coverPalettes[doc.paletteIndex % _coverPalettes.length];
    final color = palette['color']!;
    final accent = palette['accent']!;
    final hasLocalPath = doc.filePath != null && File(doc.filePath!).existsSync();

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppTheme.softShadow,
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openDocument(doc),
          onLongPress: () => _confirmDeleteDocument(doc),
          child: Padding(
            padding: const EdgeInsets.all(14.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Notebook Cover Preview Mockup
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Stack(
                      children: [
                        // Left decorative binder spine
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: 8,
                          child: Container(
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.3),
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(14),
                                bottomLeft: Radius.circular(14),
                              ),
                            ),
                          ),
                        ),

                        // Center icon
                        Center(
                          child: Icon(
                            hasLocalPath
                                ? CupertinoIcons.doc_text_fill
                                : CupertinoIcons.cloud_download_fill,
                            size: 36,
                            color: accent,
                          ),
                        ),

                        // Top Right Tag
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (doc.isCloudSynced) ...[
                                  const Icon(
                                    CupertinoIcons.cloud_fill,
                                    size: 10,
                                    color: AppTheme.primaryPurple,
                                  ),
                                  const SizedBox(width: 3),
                                ],
                                Text(
                                  doc.annotationsCount > 0
                                      ? '${doc.annotationsCount} edits'
                                      : (hasLocalPath ? 'Local' : 'Cloud'),
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // Title
                Text(
                  doc.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),

                const SizedBox(height: 4),

                // Subtitle / page status & timestamp
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        hasLocalPath ? 'Available on device' : 'Synced on Cloud',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: hasLocalPath
                              ? const Color(0xFF10B981)
                              : AppTheme.primaryPurple,
                        ),
                      ),
                    ),
                    Text(
                      doc.formattedRelativeDate,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
