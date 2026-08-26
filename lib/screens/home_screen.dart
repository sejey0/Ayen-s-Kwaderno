import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/document_item_model.dart';
import '../models/handwriting_note_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/pdf_thumbnail_widget.dart';
import '../widgets/type_note_dialog.dart';
import '../widgets/upload_document_dialog.dart';
import '../widgets/write_note_choice_dialog.dart';
import 'editor_screen.dart';

enum LibrarySection {
  all,
  documents,
  notes,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isLoadingCloudDocuments = false;

  LibrarySection _currentSection = LibrarySection.all;

  // Persistent dynamic document and handwriting note lists
  List<DocumentItem> _documents = [];
  List<HandwritingNote> _handwritingNotes = [];

  // Palette generator for handwriting sticky notes
  static const List<Map<String, Color>> _notePalettes = [
    {
      'bg': Color(0xFFFEF9C3),
      'border': Color(0xFFFDE047),
      'accent': Color(0xFFCA8A04),
    },
    {
      'bg': Color(0xFFF3E8FF),
      'border': Color(0xFFE9D5FF),
      'accent': AppTheme.primaryPurple,
    },
    {
      'bg': Color(0xFFFFEEF3),
      'border': Color(0xFFFFD6E4),
      'accent': AppTheme.accentPink,
    },
    {
      'bg': Color(0xFFE0F2FE),
      'border': Color(0xFFBAE6FD),
      'accent': Color(0xFF0284C7),
    },
    {
      'bg': Color(0xFFDCFCE7),
      'border': Color(0xFFBBF7D0),
      'accent': Color(0xFF16A34A),
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  /// Initial load: loads local cache instantly, then syncs with Supabase in background
  Future<void> _loadInitialData() async {
    // 1. Instant local load
    final localDocs = await DocumentStorageService.loadSavedDocuments();
    final localNotes = await DocumentStorageService.loadHandwritingNotes();
    if (mounted) {
      setState(() {
        _documents = localDocs;
        _handwritingNotes = localNotes;
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
          .select(
              'document_name, updated_at, strokes_data, texts_data, images_data')
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
          cloudUpdatedAt =
              DateTime.tryParse(updatedAtStr)?.toLocal() ?? DateTime.now();
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
            paletteIndex: 0,
          );
        }

        // Persist merged document
        await DocumentStorageService.saveOrUpdateDocument(docMap[docName]!);
      }

      final mergedList = docMap.values.toList()
        ..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));

      // 2. Fetch and merge Handwriting Notes from Supabase
      List<HandwritingNote> mergedNotes =
          await DocumentStorageService.loadHandwritingNotes();
      try {
        final notesResponse = await client
            .from('handwriting_notes')
            .select()
            .order('updated_at', ascending: false);

        final Map<String, HandwritingNote> noteMap = {
          for (var n in mergedNotes) n.id: n
        };

        for (final row in notesResponse) {
          final note = HandwritingNote.fromJson(Map<String, dynamic>.from(row))
              .copyWith(isCloudSynced: true);
          noteMap[note.id] = note;
          await DocumentStorageService.saveOrUpdateHandwritingNote(note);
        }

        mergedNotes = noteMap.values.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      } catch (noteErr) {
        debugPrint('Supabase handwriting_notes notice (offline or table pending): $noteErr');
      }

      setState(() {
        _documents = mergedList;
        _handwritingNotes = mergedNotes;
        _isLoadingCloudDocuments = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingCloudDocuments = false);
      debugPrint('Cloud sync notice: $e');
    }
  }

  /// Opens the Upload Document or Image modal with preview and title editor
  Future<void> _pickAndOpenDocument() async {
    final uploadedDoc = await UploadDocumentDialog.show(context);
    if (uploadedDoc != null) {
      _loadInitialData();
    }
  }

  /// Launches Write a Note Choice Modal (Handwritten Note vs Type Note)
  Future<void> _launchHandwritingToText() async {
    final savedNote = await WriteNoteChoiceDialog.show(context);

    if (!mounted || savedNote == null) return;

    setState(() {
      final existingIndex =
          _handwritingNotes.indexWhere((n) => n.id == savedNote.id);
      if (existingIndex >= 0) {
        _handwritingNotes[existingIndex] = savedNote;
      } else {
        _handwritingNotes.insert(0, savedNote);
      }
      _currentSection = LibrarySection.notes;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(CupertinoIcons.checkmark_circle_fill,
                color: Color(0xFF10B981), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Saved "${savedNote.title}" to Written Notes! ✍️',
                style: const TextStyle(fontWeight: FontWeight.w600),
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
  }

  /// Opens a saved document card
  Future<void> _openDocument(DocumentItem doc) async {
    final path = doc.filePath;

    if (path != null && File(path).existsSync()) {
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

      _loadInitialData();
    } else {
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
                allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'bmp'],
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
                _loadInitialData();
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

  /// Displays and allows editing a saved handwriting note
  Future<void> _openHandwritingNoteDialog(HandwritingNote note) async {
    final updated = await TypeNoteDialog.show(context, existingNote: note);
    if (updated != null && mounted) {
      setState(() {
        final idx = _handwritingNotes.indexWhere((n) => n.id == updated.id);
        if (idx >= 0) {
          _handwritingNotes[idx] = updated;
        }
      });
    }
  }

  /// Deletes a document from the recent list with confirmation
  void _confirmDeleteDocument(DocumentItem doc) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Remove from Recent?'),
        content: Text(
          'Do you want to remove "${doc.fileName}" from your documents list? Cloud annotations will remain preserved.',
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

  /// Deletes a handwriting note with confirmation
  void _confirmDeleteNote(HandwritingNote note) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Delete Note?'),
        content: Text('Do you want to delete "${note.title}"?'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Delete'),
            onPressed: () async {
              Navigator.pop(context);
              await DocumentStorageService.deleteHandwritingNote(note.id);
              setState(() {
                _handwritingNotes.removeWhere((n) => n.id == note.id);
              });
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showDocs = _currentSection == LibrarySection.all ||
        _currentSection == LibrarySection.documents;
    final showNotes = _currentSection == LibrarySection.all ||
        _currentSection == LibrarySection.notes;

    final totalDocsCount = _documents.length;
    final totalNotesCount = _handwritingNotes.length;

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

              const SliverToBoxAdapter(child: SizedBox(height: 24)),

              // Main Section Switcher Tabs (All Items, PDF Documents, Handwritten Notes)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: _buildSectionSwitcher(
                      totalDocsCount, totalNotesCount),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 18)),

              // ==========================================
              // 1. UPLOADED DOCUMENTS & IMAGES SECTION
              // ==========================================
              if (showDocs) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              CupertinoIcons.doc_text_fill,
                              color: AppTheme.primaryPurple,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Documents & Images ($totalDocsCount)',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                            if (_isLoadingCloudDocuments) ...[
                              const SizedBox(width: 8),
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.primaryPurple,
                                ),
                              ),
                            ],
                          ],
                        ),
                        GestureDetector(
                          onTap: _pickAndOpenDocument,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryPurpleLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.cloud_upload_fill,
                                    size: 13, color: AppTheme.primaryPurple),
                                SizedBox(width: 4),
                                Text(
                                  'Upload',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.primaryPurpleDark,
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
                const SliverToBoxAdapter(child: SizedBox(height: 10)),
                if (_documents.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20.0, vertical: 4.0),
                      child: _buildEmptyDocumentsCard(),
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
                          final doc = _documents[index];
                          return _buildNotebookCard(doc);
                        },
                        childCount: _documents.length,
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],

              // ==========================================
              // 2. WRITE A NOTE / WRITTEN NOTES SECTION
              // ==========================================
              if (showNotes) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              CupertinoIcons.pencil_ellipsis_rectangle,
                              color: AppTheme.accentPink,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Written Notes ($totalNotesCount)',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ],
                        ),
                        GestureDetector(
                          onTap: _launchHandwritingToText,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppTheme.accentPinkLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.pencil,
                                    size: 13, color: AppTheme.accentPinkDark),
                                SizedBox(width: 3),
                                Text(
                                  'Write a Note',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.accentPinkDark,
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
                const SliverToBoxAdapter(child: SizedBox(height: 10)),
                if (_handwritingNotes.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20.0, vertical: 4.0),
                      child: _buildEmptyNotesCard(),
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
                        childAspectRatio: 0.85,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final note = _handwritingNotes[index];
                          return _buildHandwritingNoteCard(note);
                        },
                        childCount: _handwritingNotes.length,
                      ),
                    ),
                  ),
              ],

              const SliverToBoxAdapter(child: SizedBox(height: 90)),
            ],
          ),
        ),
      ),

      // Floating Action Button for Quick Upload or Note Creation
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _currentSection == LibrarySection.notes
            ? _launchHandwritingToText
            : _pickAndOpenDocument,
        backgroundColor: _currentSection == LibrarySection.notes
            ? AppTheme.primaryPurple
            : AppTheme.accentPink,
        foregroundColor: Colors.white,
        elevation: 4,
        icon: Icon(
          _currentSection == LibrarySection.notes
              ? CupertinoIcons.pencil_outline
              : CupertinoIcons.cloud_upload_fill,
          size: 20,
        ),
        label: Text(
          _currentSection == LibrarySection.notes ? 'Write a Note' : 'Upload Document',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }

  /// Segmented Section Switcher (All, Documents, Notes)
  Widget _buildSectionSwitcher(int docsCount, int notesCount) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.dividerColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildSwitcherTab(
            label: 'All',
            badge: '${docsCount + notesCount}',
            section: LibrarySection.all,
          ),
          _buildSwitcherTab(
            label: 'Documents',
            badge: '$docsCount',
            section: LibrarySection.documents,
          ),
          _buildSwitcherTab(
            label: 'Notes',
            badge: '$notesCount',
            section: LibrarySection.notes,
          ),
        ],
      ),
    );
  }

  Widget _buildSwitcherTab({
    required String label,
    required String badge,
    required LibrarySection section,
  }) {
    final isSelected = _currentSection == section;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _currentSection = section),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primaryPurple : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                    color: isSelected ? Colors.white : AppTheme.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.25)
                      : AppTheme.primaryPurpleLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color:
                        isSelected ? Colors.white : AppTheme.primaryPurpleDark,
                  ),
                ),
              ),
            ],
          ),
        ),
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
                  'Your Study Notebooks & Handwritten Notes ✨',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
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
                            'Annotate PDF documents & images, or write notes instantly.',
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
                Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _pickAndOpenDocument,
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
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: const Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  Icon(CupertinoIcons.cloud_upload_fill,
                                      size: 17, color: Colors.white),
                                  SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Upload Documents or Images',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.2,
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
                    const SizedBox(width: 10),
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
                                const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                CupertinoIcons.pencil_ellipsis_rectangle,
                                size: 17,
                                color: AppTheme.primaryPurpleDark,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Write a Note',
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

  /// Empty State card for Documents or Images section
  Widget _buildEmptyDocumentsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: const Column(
        children: [
          Icon(CupertinoIcons.doc_text_search,
              size: 32, color: AppTheme.primaryPurple),
          SizedBox(height: 8),
          Text(
            'No Documents or Images Yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14.5,
              color: AppTheme.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Upload a PDF document or image to highlight, draw lines, and add notes.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  /// Empty State card for Written Notes section
  Widget _buildEmptyNotesCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: const Column(
        children: [
          Icon(CupertinoIcons.pencil_ellipsis_rectangle,
              size: 32, color: AppTheme.accentPink),
          SizedBox(height: 8),
          Text(
            'No Notes Written Yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14.5,
              color: AppTheme.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Tap "Write a Note" to convert your handwriting or type digital study notes.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  /// Study Notebook Card (PDF & Image Documents)
  Widget _buildNotebookCard(DocumentItem doc) {
    final pathLower = (doc.filePath ?? '').toLowerCase();
    final isImg = pathLower.endsWith('.png') ||
        pathLower.endsWith('.jpg') ||
        pathLower.endsWith('.jpeg') ||
        pathLower.endsWith('.webp') ||
        pathLower.endsWith('.bmp');

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
            Expanded(
              child: Stack(
                children: [
                  // Real Content Preview of PDF page 1 or Image
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(19),
                        topRight: Radius.circular(19),
                      ),
                      child: DocumentThumbnailPreview(
                        filePath: doc.filePath,
                        fileName: doc.fileName,
                        backgroundColor: const Color(0xFFF1F5F9),
                        accentColor: AppTheme.primaryPurple,
                      ),
                    ),
                  ),

                  // Format Badge (PDF or IMAGE)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isImg ? 'IMG' : 'PDF',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 0.4,
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
                          color: Colors.white.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
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

  /// Handwriting Sticky Note Card
  Widget _buildHandwritingNoteCard(HandwritingNote note) {
    final palette = _notePalettes[note.paletteIndex % _notePalettes.length];
    final bg = palette['bg']!;
    final border = palette['border']!;
    final accent = palette['accent']!;

    return GestureDetector(
      onTap: () => _openHandwritingNoteDialog(note),
      onLongPress: () => _confirmDeleteNote(note),
      child: Container(
        padding: const EdgeInsets.all(14.0),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: border, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Bar: Note Pin & Copy action
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(CupertinoIcons.pin_fill, size: 13, color: accent),
                    const SizedBox(width: 4),
                    Text(
                      _formatTimestamp(note.updatedAt),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: accent.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: note.content));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Copied "${note.title}"! 📋'),
                        duration: const Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Icon(
                    CupertinoIcons.doc_on_clipboard,
                    size: 14,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Note Title
            Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),

            // Note Content Snippet
            Expanded(
              child: Text(
                note.content,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF4B5563),
                  height: 1.35,
                ),
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
