import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/document_item_model.dart';
import '../models/handwriting_note_model.dart';
import '../models/user_profile_model.dart';
import '../services/auto_sync_service.dart';
import '../services/document_storage_service.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import '../widgets/account_profile_dialog.dart';
import '../widgets/app_side_navigation_panel.dart';
import '../widgets/handwriting_canvas.dart';
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

  // Sidebar navigation panel state
  SidebarNavItem _selectedSidebarNav = SidebarNavItem.dashboard;
  bool _isSidebarExpanded = true;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Persistent dynamic document and handwriting note lists
  List<DocumentItem> _documents = [];
  List<HandwritingNote> _handwritingNotes = [];

  // Multi-select mode state
  bool _isSelectionMode = false;
  final Set<String> _selectedDocFileNames = {};
  final Set<String> _selectedNoteIds = {};

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
    AutoSyncService.instance.statusNotifier
        .addListener(_onSyncStatusUpdated);
    UserService.instance.currentUserNotifier
        .addListener(_onUserChanged);
    _loadInitialData();
  }

  @override
  void dispose() {
    AutoSyncService.instance.statusNotifier
        .removeListener(_onSyncStatusUpdated);
    UserService.instance.currentUserNotifier
        .removeListener(_onUserChanged);
    super.dispose();
  }

  void _onUserChanged() {
    if (mounted) {
      _loadInitialData();
    }
  }

  void _onSyncStatusUpdated() {
    if (mounted) {
      _loadInitialData(triggerCloudFetch: false);
    }
  }

  /// Initial load: loads local cache instantly, then syncs with Supabase in background
  Future<void> _loadInitialData({bool triggerCloudFetch = true}) async {
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
    if (triggerCloudFetch) {
      await _syncWithCloud();
    }
  }

  /// Fetches saved document annotations and notes from Supabase strictly for active user
  Future<void> _syncWithCloud() async {
    try {
      setState(() => _isLoadingCloudDocuments = true);
      await AutoSyncService.instance.syncAllToCloud();

      final activeUserId = UserService.instance.activeUserId;
      final localDocs =
          await DocumentStorageService.loadSavedDocuments(activeUserId);
      final localNotes =
          await DocumentStorageService.loadHandwritingNotes(activeUserId);

      if (!mounted) return;
      setState(() {
        _documents = localDocs;
        _handwritingNotes = localNotes;
        _isLoadingCloudDocuments = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingCloudDocuments = false);
      debugPrint('Cloud sync notice: $e');
    }
  }

  /// Opens Profile Settings and displays a verification modal if the user switched accounts
  Future<void> _openProfileSettings() async {
    final switchedProfile = await AccountProfileDialog.show(context);
    if (switchedProfile != null && mounted) {
      _showAccountSwitchedModal(switchedProfile);
    }
  }

  /// Verification modal shown upon successfully switching account
  void _showAccountSwitchedModal(UserProfile user) {
    showDialog(
      context: context,
      builder: (dialogCtx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: AppTheme.surfaceWhite,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Avatar with checkmark badge
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Container(
                    width: 72,
                    height: 72,
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
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        user.avatarEmoji,
                        style: const TextStyle(fontSize: 34),
                      ),
                    ),
                  ),
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(
                      CupertinoIcons.checkmark,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // Title
              Text(
                'Switched to ${user.name}!',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.textPrimary,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 8),

              // Status chip
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: user.isCloudLinked
                      ? const Color(0xFFECFDF5)
                      : AppTheme.primaryPurpleLight,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: user.isCloudLinked
                        ? const Color(0xFF10B981).withValues(alpha: 0.3)
                        : AppTheme.primaryPurple.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      user.isCloudLinked
                          ? CupertinoIcons.cloud_fill
                          : CupertinoIcons.device_phone_portrait,
                      size: 13,
                      color: user.isCloudLinked
                          ? const Color(0xFF065F46)
                          : AppTheme.primaryPurple,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      user.isCloudLinked
                          ? (user.email ?? 'Cloud Synced')
                          : 'Offline Notebook Space',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: user.isCloudLinked
                            ? const Color(0xFF065F46)
                            : AppTheme.primaryPurpleDark,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              Text(
                user.isCloudLinked
                    ? 'All notes and documents for ${user.name} have been synchronized and loaded.'
                    : 'Local notes and drawings for ${user.name} are loaded and ready on this device.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),

              // Got it / Open Workspace button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryPurple,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Open Workspace',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
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

  /// Handles selection of items from the dynamic Side Navigation Panel
  void _handleSidebarNavSelected(SidebarNavItem item) {
    setState(() => _selectedSidebarNav = item);
    switch (item) {
      case SidebarNavItem.dashboard:
        setState(() => _currentSection = LibrarySection.all);
        break;
      case SidebarNavItem.documents:
        setState(() => _currentSection = LibrarySection.documents);
        break;
      case SidebarNavItem.notes:
        setState(() => _currentSection = LibrarySection.notes);
        break;
      case SidebarNavItem.settings:
        _openProfileSettings();
        break;
      case SidebarNavItem.aiOcr:
        _launchHandwritingToText();
        break;
      case SidebarNavItem.archive:
        _showArchiveInfoDialog();
        break;
      case SidebarNavItem.help:
        _showHelpInfoDialog();
        break;
    }
  }

  void _showArchiveInfoDialog() {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Archive & Trash'),
        content: const Text(
          'Archived items and notes are scoped per user profile. Cloud-backed notes are backed up safely with Supabase.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Got it'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  void _showHelpInfoDialog() {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text("About Ayen's Kwaderno"),
        content: const Text(
          "Ayen's Kwaderno is your smart offline-first digital notebook with AI handwriting, PDF annotation, and real-time Supabase cloud sync.\n\nVersion: 1.2.0\nTheme: Digital Stationery",
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Close'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
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
    final mode = await WriteNoteChoiceDialog.show(context);
    if (!mounted || mode == null) return;

    HandwritingNote? savedNote;
    if (mode == NoteCreationMode.handwritten) {
      savedNote = await HandwritingCanvasDialog.show(context);
    } else {
      savedNote = await TypeNoteDialog.show(context);
    }

    if (!mounted || savedNote == null) return;
    final note = savedNote;

    setState(() {
      final existingIndex =
          _handwritingNotes.indexWhere((n) => n.id == note.id);
      if (existingIndex >= 0) {
        _handwritingNotes[existingIndex] = note;
      } else {
        _handwritingNotes.insert(0, note);
      }
      _currentSection = LibrarySection.notes;
    });

    _loadInitialData();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(CupertinoIcons.checkmark_circle_fill,
                color: Color(0xFF10B981), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Saved "${note.title}" to Written Notes! ✍️',
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
    String? validPath = doc.filePath;

    // 1. Check if stored path exists
    if (validPath != null && File(validPath).existsSync()) {
      // Path exists!
    } else {
      // 2. Check saved_documents directory
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final savedDocsDir = Directory('${appDir.path}/saved_documents');
        if (savedDocsDir.existsSync()) {
          final candidates = [
            File('${savedDocsDir.path}/${doc.fileName}'),
            File('${savedDocsDir.path}/${doc.fileName}.pdf'),
          ];
          for (final f in candidates) {
            if (f.existsSync()) {
              validPath = f.path;
              break;
            }
          }
        }
      } catch (_) {}
    }

    if (validPath != null && File(validPath).existsSync()) {
      final updated = doc.copyWith(
        filePath: validPath,
        lastOpenedAt: DateTime.now(),
      );
      await DocumentStorageService.saveOrUpdateDocument(updated);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => EditorScreen(
            pdfPath: validPath!,
            fileName: doc.fileName,
          ),
        ),
      );

      _loadInitialData();
      return;
    }

    // 3. Prompt user directly to pick the document file to open with cloud annotations
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'bmp'],
      dialogTitle: 'Select "${doc.fileName}" to view and edit',
    );

    if (picked != null && picked.path != null) {
      String persistentPath = picked.path!;
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final savedDocsDir = Directory('${appDir.path}/saved_documents');
        if (!savedDocsDir.existsSync()) {
          savedDocsDir.createSync(recursive: true);
        }
        final permanentFile = File('${savedDocsDir.path}/${doc.fileName}');
        if (permanentFile.path != persistentPath) {
          await File(persistentPath).copy(permanentFile.path);
          persistentPath = permanentFile.path;
        }
      } catch (_) {}

      final updatedDoc = doc.copyWith(
        filePath: persistentPath,
        lastOpenedAt: DateTime.now(),
      );
      await DocumentStorageService.saveOrUpdateDocument(updatedDoc);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => EditorScreen(
            pdfPath: persistentPath,
            fileName: doc.fileName,
          ),
        ),
      );
      _loadInitialData();
    }
  }

  /// Displays and allows editing a saved handwriting or typed note
  Future<void> _openHandwritingNoteDialog(HandwritingNote note) async {
    HandwritingNote? updated;
    if (note.isHandwritten) {
      updated =
          await HandwritingCanvasDialog.show(context, existingNote: note);
    } else {
      updated = await TypeNoteDialog.show(context, existingNote: note);
    }

    if (updated != null && mounted) {
      final noteResult = updated;
      setState(() {
        final idx = _handwritingNotes.indexWhere((n) => n.id == noteResult.id);
        if (idx >= 0) {
          _handwritingNotes[idx] = noteResult;
        }
      });
      _loadInitialData();
    }
  }


  // ==========================================
  // MULTI-SELECT BULK DELETE HELPERS
  // ==========================================

  void _enterSelectionMode() {
    setState(() {
      _isSelectionMode = true;
      _selectedDocFileNames.clear();
      _selectedNoteIds.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedDocFileNames.clear();
      _selectedNoteIds.clear();
    });
  }

  void _toggleDocSelection(String fileName) {
    setState(() {
      if (_selectedDocFileNames.contains(fileName)) {
        _selectedDocFileNames.remove(fileName);
      } else {
        _selectedDocFileNames.add(fileName);
      }
    });
  }

  void _toggleNoteSelection(String noteId) {
    setState(() {
      if (_selectedNoteIds.contains(noteId)) {
        _selectedNoteIds.remove(noteId);
      } else {
        _selectedNoteIds.add(noteId);
      }
    });
  }

  void _selectAllVisible() {
    setState(() {
      final showDocs = _currentSection == LibrarySection.all ||
          _currentSection == LibrarySection.documents;
      final showNotes = _currentSection == LibrarySection.all ||
          _currentSection == LibrarySection.notes;

      if (showDocs) {
        for (final doc in _documents) {
          _selectedDocFileNames.add(doc.fileName);
        }
      }
      if (showNotes) {
        for (final note in _handwritingNotes) {
          _selectedNoteIds.add(note.id);
        }
      }
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedDocFileNames.clear();
      _selectedNoteIds.clear();
    });
  }

  int get _totalSelectedCount =>
      _selectedDocFileNames.length + _selectedNoteIds.length;

  int get _visibleItemsCount {
    final showDocs = _currentSection == LibrarySection.all ||
        _currentSection == LibrarySection.documents;
    final showNotes = _currentSection == LibrarySection.all ||
        _currentSection == LibrarySection.notes;

    int count = 0;
    if (showDocs) count += _documents.length;
    if (showNotes) count += _handwritingNotes.length;
    return count;
  }

  bool get _isAllVisibleSelected {
    if (_visibleItemsCount == 0) return false;
    final showDocs = _currentSection == LibrarySection.all ||
        _currentSection == LibrarySection.documents;
    final showNotes = _currentSection == LibrarySection.all ||
        _currentSection == LibrarySection.notes;

    if (showDocs) {
      for (final d in _documents) {
        if (!_selectedDocFileNames.contains(d.fileName)) return false;
      }
    }
    if (showNotes) {
      for (final n in _handwritingNotes) {
        if (!_selectedNoteIds.contains(n.id)) return false;
      }
    }
    return true;
  }

  void _confirmBulkDelete() {
    final count = _totalSelectedCount;
    if (count == 0) return;

    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Delete Selected?'),
        content: Text(
          'Are you sure you want to delete $count selected item${count == 1 ? '' : 's'}? This cannot be undone.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: Text('Delete $count Item${count == 1 ? '' : 's'}'),
            onPressed: () async {
              Navigator.pop(context);
              await _executeBulkDelete();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _executeBulkDelete() async {
    final count = _totalSelectedCount;

    // Delete selected documents
    for (final fileName in _selectedDocFileNames) {
      await DocumentStorageService.deleteDocument(fileName);
    }
    // Delete selected notes
    for (final noteId in _selectedNoteIds) {
      await DocumentStorageService.deleteHandwritingNote(noteId);
    }

    setState(() {
      _documents.removeWhere(
          (d) => _selectedDocFileNames.contains(d.fileName));
      _handwritingNotes.removeWhere(
          (n) => _selectedNoteIds.contains(n.id));
      _isSelectionMode = false;
      _selectedDocFileNames.clear();
      _selectedNoteIds.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(CupertinoIcons.trash_fill,
                  color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                'Deleted $count item${count == 1 ? '' : 's'} successfully! 🗑️',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Floating Action Bar shown during multi-select mode
  Widget _buildSelectionBottomBar() {
    final count = _totalSelectedCount;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(
          color: count > 0
              ? const Color(0xFFEF4444).withValues(alpha: 0.3)
              : AppTheme.dividerColor,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: _exitSelectionMode,
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          ElevatedButton.icon(
            onPressed: count > 0 ? _confirmBulkDelete : null,
            icon: const Icon(CupertinoIcons.trash_fill, size: 16),
            label: Text(
              count > 0 ? 'Delete ($count)' : 'Delete',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  const Color(0xFFEF4444).withValues(alpha: 0.35),
              disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              elevation: count > 0 ? 3 : 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideScreen = constraints.maxWidth >= 800;

        final mainContent = RefreshIndicator(
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
        );

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: AppTheme.background,
          drawer: isWideScreen
              ? null
              : Drawer(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  child: AppSideNavigationPanel(
                    isDrawerMode: true,
                    selectedItem: _selectedSidebarNav,
                    onItemSelected: _handleSidebarNavSelected,
                    onCloseDrawer: () =>
                        _scaffoldKey.currentState?.closeDrawer(),
                  ),
                ),
          body: SafeArea(
            child: isWideScreen
                ? Row(
                    children: [
                      AppSideNavigationPanel(
                        isDrawerMode: false,
                        initiallyExpanded: _isSidebarExpanded,
                        onExpansionChanged: (exp) =>
                            setState(() => _isSidebarExpanded = exp),
                        selectedItem: _selectedSidebarNav,
                        onItemSelected: _handleSidebarNavSelected,
                      ),
                      Expanded(child: mainContent),
                    ],
                  )
                : mainContent,
          ),
          floatingActionButtonLocation: _isSelectionMode
              ? FloatingActionButtonLocation.centerFloat
              : FloatingActionButtonLocation.endFloat,
          floatingActionButton: _isSelectionMode
              ? _buildSelectionBottomBar()
              : FloatingActionButton.extended(
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
                    _currentSection == LibrarySection.notes
                        ? 'Write a Note'
                        : 'Upload Document',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
        );
      },
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

  /// Top Profile & Greeting Row or Multi-Select Header
  Widget _buildHeader() {
    if (_isSelectionMode) {
      final allSelected = _isAllVisibleSelected;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.surfaceWhite,
          borderRadius: BorderRadius.circular(18),
          boxShadow: AppTheme.softShadow,
          border: Border.all(
            color: AppTheme.primaryPurple.withValues(alpha: 0.35),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(CupertinoIcons.xmark_circle_fill,
                  color: AppTheme.textSecondary, size: 24),
              tooltip: 'Cancel selection',
              onPressed: _exitSelectionMode,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$_totalSelectedCount Selected',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: allSelected ? _deselectAll : _selectAllVisible,
              icon: Icon(
                allSelected
                    ? CupertinoIcons.clear_circled
                    : CupertinoIcons.checkmark_circle_fill,
                size: 16,
                color: AppTheme.primaryPurple,
              ),
              label: Text(
                allSelected ? 'Deselect All' : 'Select All',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  color: AppTheme.primaryPurple,
                ),
              ),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                backgroundColor: AppTheme.primaryPurpleLight,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final hasItems = _documents.isNotEmpty || _handwritingNotes.isNotEmpty;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            // Side Navigation Drawer / Sidebar Toggle Button
            Builder(
              builder: (ctx) => Container(
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceWhite,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.dividerColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.03),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: IconButton(
                  icon: const Icon(CupertinoIcons.bars,
                      size: 20, color: AppTheme.textPrimary),
                  tooltip: 'Menu & Navigation',
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    final isWide = MediaQuery.of(context).size.width >= 800;
                    if (isWide) {
                      setState(() => _isSidebarExpanded = !_isSidebarExpanded);
                    } else {
                      _scaffoldKey.currentState?.openDrawer();
                    }
                  },
                ),
              ),
            ),

            // App Branding Title & Icon (Tapping directly opens Profile Settings)
            GestureDetector(
              onTap: _openProfileSettings,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          AppTheme.primaryPurple,
                          AppTheme.accentPink
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text('📓', style: TextStyle(fontSize: 20)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    "Ayen's Kwaderno",
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.textPrimary,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),
      ],
    ),
    Row(
      children: [
            if (hasItems) ...[
              Container(
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceWhite,
                  shape: BoxShape.circle,
                  boxShadow: AppTheme.softShadow,
                  border: Border.all(color: AppTheme.dividerColor),
                ),
                child: IconButton(
                  icon: const Icon(CupertinoIcons.checkmark_circle,
                      color: AppTheme.primaryPurple, size: 20),
                  tooltip: 'Select items to delete',
                  onPressed: _enterSelectionMode,
                ),
              ),
            ],
            ValueListenableBuilder<AutoSyncStatus>(
              valueListenable: AutoSyncService.instance.statusNotifier,
              builder: (context, status, _) {
                Color iconColor = const Color(0xFF10B981);
                IconData iconData = CupertinoIcons.cloud_fill;
                String tooltip =
                    'Auto-uploaded to Supabase Database ✨ (Tap to refresh)';
                Widget? customChild;

                switch (status) {
                  case AutoSyncStatus.syncing:
                    iconColor = AppTheme.primaryPurple;
                    tooltip = 'Auto-uploading to Supabase Cloud...';
                    customChild = const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: AppTheme.primaryPurple,
                      ),
                    );
                    break;
                  case AutoSyncStatus.offline:
                    iconColor = const Color(0xFF94A3B8);
                    iconData = Icons.cloud_off_rounded;
                    tooltip =
                        'Offline • Changes saved locally & will auto-upload online';
                    break;
                  case AutoSyncStatus.error:
                    iconColor = const Color(0xFFEF4444);
                    iconData = CupertinoIcons.exclamationmark_triangle;
                    tooltip = 'Sync notice • Tap to retry';
                    break;
                  case AutoSyncStatus.synced:
                    iconColor = const Color(0xFF10B981);
                    iconData = CupertinoIcons.cloud_fill;
                    tooltip =
                        'Auto-uploaded to Supabase Database ✨ (Tap to refresh)';
                    break;
                }

                return Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    shape: BoxShape.circle,
                    boxShadow: AppTheme.softShadow,
                    border: Border.all(
                      color: status == AutoSyncStatus.synced
                          ? const Color(0xFF10B981).withValues(alpha: 0.3)
                          : AppTheme.dividerColor,
                    ),
                  ),
                  child: IconButton(
                    icon: customChild ??
                        Icon(iconData, color: iconColor, size: 20),
                    tooltip: tooltip,
                    onPressed: () {
                      AutoSyncService.instance.triggerSync(immediate: true);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            children: [
                              Icon(
                                status == AutoSyncStatus.offline
                                    ? CupertinoIcons.wifi_slash
                                    : CupertinoIcons.checkmark_circle_fill,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  status == AutoSyncStatus.offline
                                      ? 'Offline mode active. All notes will auto-upload the instant you go online! ⚡'
                                      : 'Database auto-sync refreshed with Supabase! ✨',
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
                    },
                  ),
                );
              },
            ),
          ],
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
    final isSelected = _selectedDocFileNames.contains(doc.fileName);

    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          _toggleDocSelection(doc.fileName);
        } else {
          _openDocument(doc);
        }
      },
      onLongPress: () {
        if (_isSelectionMode) {
          _toggleDocSelection(doc.fileName);
        } else {
          HapticFeedback.mediumImpact();
          _enterSelectionMode();
          _toggleDocSelection(doc.fileName);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryPurpleLight.withValues(alpha: 0.35)
              : AppTheme.surfaceWhite,
          borderRadius: BorderRadius.circular(20),
          boxShadow: AppTheme.softShadow,
          border: Border.all(
            color: isSelected
                ? AppTheme.primaryPurple
                : AppTheme.dividerColor,
            width: isSelected ? 2.2 : 1.0,
          ),
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

                  // Selection Checkbox Badge OR Format Badge
                  if (_isSelectionMode)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected
                              ? AppTheme.primaryPurple
                              : Colors.white.withValues(alpha: 0.95),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.primaryPurple
                                : AppTheme.dividerColor,
                            width: 2.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: isSelected
                            ? const Icon(CupertinoIcons.checkmark,
                                size: 14, color: Colors.white)
                            : null,
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

                  // Cloud Synced Badge (only when not in selection mode)
                  if (doc.isCloudSynced && !_isSelectionMode)
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

  /// Handwriting Sticky Note Card (or Real Handwritten Canvas Preview)
  Widget _buildHandwritingNoteCard(HandwritingNote note) {
    final isSelected = _selectedNoteIds.contains(note.id);

    if (note.isHandwritten) {
      final strokes = (note.strokesJson ?? [])
          .map((s) => HandwritingStroke.fromJson(s))
          .toList();

      return GestureDetector(
        onTap: () {
          if (_isSelectionMode) {
            _toggleNoteSelection(note.id);
          } else {
            _openHandwritingNoteDialog(note);
          }
        },
        onLongPress: () {
          if (_isSelectionMode) {
            _toggleNoteSelection(note.id);
          } else {
            HapticFeedback.mediumImpact();
            _enterSelectionMode();
            _toggleNoteSelection(note.id);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.primaryPurpleLight.withValues(alpha: 0.35)
                : AppTheme.surfaceWhite,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isSelected
                  ? AppTheme.primaryPurple
                  : AppTheme.dividerColor,
              width: isSelected ? 2.2 : 1.0,
            ),
            boxShadow: AppTheme.softShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Real Handwritten Drawing Canvas Preview with selection checkbox
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.15),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CustomPaint(
                          painter: HandwritingCanvasPainter(
                            strokes: strokes,
                            fitThumbnail: true,
                          ),
                        ),
                      ),
                    ),
                    if (_isSelectionMode)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected
                                ? AppTheme.primaryPurple
                                : Colors.white.withValues(alpha: 0.95),
                            border: Border.all(
                              color: isSelected
                                  ? AppTheme.primaryPurple
                                  : AppTheme.dividerColor,
                              width: 2.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: isSelected
                              ? const Icon(CupertinoIcons.checkmark,
                                  size: 14, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: AppTheme.primaryPurpleLight,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text(
                                '2 Pages',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.primaryPurpleDark,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${strokes.length} stroke${strokes.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          _formatTimestamp(note.updatedAt),
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
            ],
          ),
        ),
      );
    }

    final palette = _notePalettes[note.paletteIndex % _notePalettes.length];
    final bg = palette['bg']!;
    final border = palette['border']!;
    final accent = palette['accent']!;

    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          _toggleNoteSelection(note.id);
        } else {
          _openHandwritingNoteDialog(note);
        }
      },
      onLongPress: () {
        if (_isSelectionMode) {
          _toggleNoteSelection(note.id);
        } else {
          HapticFeedback.mediumImpact();
          _enterSelectionMode();
          _toggleNoteSelection(note.id);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14.0),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryPurpleLight.withValues(alpha: 0.35)
              : bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? AppTheme.primaryPurple : border,
            width: isSelected ? 2.5 : 1.2,
          ),
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
            // Top Bar: Note Pin / Selection Checkbox & Copy action
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_isSelectionMode)
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected
                          ? AppTheme.primaryPurple
                          : Colors.white.withValues(alpha: 0.9),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.primaryPurple
                            : AppTheme.dividerColor,
                        width: 1.8,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(CupertinoIcons.checkmark,
                            size: 13, color: Colors.white)
                        : null,
                  )
                else
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
                if (!_isSelectionMode)
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
                  )
                else
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
