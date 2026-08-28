import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_pdfviewer_platform_interface/pdfviewer_platform_interface.dart';
import '../models/document_item_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';
import '../screens/editor_screen.dart';

/// Modal bottom sheet for uploading and previewing PDF documents or images with customizable title
class UploadDocumentDialog extends StatefulWidget {
  const UploadDocumentDialog({super.key});

  /// Static helper to launch the dialog
  static Future<DocumentItem?> show(BuildContext context) {
    return showModalBottomSheet<DocumentItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (context) => const UploadDocumentDialog(),
    );
  }

  @override
  State<UploadDocumentDialog> createState() => _UploadDocumentDialogState();
}

class _UploadDocumentDialogState extends State<UploadDocumentDialog> {
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _titleController = TextEditingController();

  String? _selectedFilePath;
  String? _selectedFileName;
  int? _selectedFileSize;
  bool _isImage = false;
  bool _isPicking = false;
  Uint8List? _pdfPage1Bytes;
  bool _userManuallyEditedTitle = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  /// Picks a document file (PDF or Image) using FilePicker
  Future<void> _pickFile() async {
    try {
      setState(() => _isPicking = true);

      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'bmp'],
      );

      if (!mounted) return;
      setState(() => _isPicking = false);

      if (picked != null && picked.path != null) {
        await _processSelectedFile(picked.path!, picked.name);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPicking = false);
      _showErrorSnackBar('Unable to pick file: $e');
    }
  }

  /// Picks photo from camera or gallery using ImagePicker
  Future<void> _pickImage(ImageSource source) async {
    try {
      setState(() => _isPicking = true);

      final XFile? photo = await _imagePicker.pickImage(
        source: source,
        imageQuality: 95,
      );

      if (!mounted) return;
      setState(() => _isPicking = false);

      if (photo != null) {
        await _processSelectedFile(photo.path, photo.name);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPicking = false);
      _showErrorSnackBar('Unable to pick image: $e');
    }
  }

  Future<void> _processSelectedFile(String path, String name) async {
    final file = File(path);
    final size = file.existsSync() ? file.lengthSync() : 0;
    final lower = path.toLowerCase();
    final isImg = lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');

    Uint8List? pdfBytes;
    if (!isImg && file.existsSync()) {
      try {
        final docId = 'upload_thumb_${DateTime.now().millisecondsSinceEpoch}';
        final platform = PdfViewerPlatform.instance;
        await platform.loadPdfFromFile(path, docId);
        pdfBytes = await platform.getPage(1, 350, 480, docId);
        await platform.closeDocument(docId);
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _selectedFilePath = path;
      _selectedFileName = name;
      _selectedFileSize = size;
      _isImage = isImg;
      _pdfPage1Bytes = pdfBytes;
      // Only auto-fill if the user hasn't typed their own custom title yet
      if (!_userManuallyEditedTitle || _titleController.text.trim().isEmpty) {
        _titleController.text = name;
      }
    });
  }

  void _clearSelectedFile() {
    setState(() {
      _selectedFilePath = null;
      _selectedFileName = null;
      _selectedFileSize = null;
      _isImage = false;
      _pdfPage1Bytes = null;
      if (!_userManuallyEditedTitle) {
        _titleController.clear();
      }
    });
  }

  Future<void> _uploadAndOpenDocument() async {
    if (_selectedFilePath == null) return;

    String persistentPath = _selectedFilePath!;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final savedDocsDir = Directory('${appDir.path}/saved_documents');
      if (!savedDocsDir.existsSync()) {
        savedDocsDir.createSync(recursive: true);
      }
      final baseName = _selectedFileName ??
          'document_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final permanentFile = File('${savedDocsDir.path}/$baseName');
      if (permanentFile.path != _selectedFilePath) {
        await File(_selectedFilePath!).copy(permanentFile.path);
        persistentPath = permanentFile.path;
      }
    } catch (_) {}

    // Use custom title if entered, otherwise fallback to filename
    final customTitle = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : (_selectedFileName ?? 'Document');

    int fileSizeInBytes = 0;
    try {
      fileSizeInBytes = File(persistentPath).lengthSync();
    } catch (_) {}

    // Supabase bucket single-file upload threshold (e.g. 50MB)
    const int maxCloudUploadSizeBytes = 50 * 1024 * 1024; // 50 MB
    final bool exceedsCloudLimit = fileSizeInBytes > maxCloudUploadSizeBytes;

    // Create & persist DocumentItem with the custom title
    final newDoc = DocumentItem(
      fileName: customTitle,
      filePath: persistentPath,
      lastOpenedAt: DateTime.now(),
      annotationsCount: 0,
      paletteIndex: DateTime.now().millisecond % 6,
      isCloudSynced: false,
    );

    await DocumentStorageService.saveOrUpdateDocument(newDoc);

    if (exceedsCloudLimit && mounted) {
      await showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(CupertinoIcons.info_circle_fill,
                  color: Color(0xFF6B4EE6), size: 22),
              SizedBox(width: 8),
              Text('Local Storage Only'),
            ],
          ),
          content: Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Text(
              'This file (${_formatFileSize(fileSizeInBytes)}) exceeds the cloud sync limit (50 MB).\n\nIt has been safely saved to your local device storage so you can open, read, and annotate it offline anytime.',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              child: const Text('Got it, Open File'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
    }

    if (!mounted) return;
    Navigator.of(context).pop(newDoc);

    // Navigate to Editor with custom title and path
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EditorScreen(
          pdfPath: persistentPath,
          fileName: customTitle,
        ),
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.textPrimary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final hasFile = _selectedFilePath != null;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88 + bottomInset,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag Handle & Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Title Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  AppTheme.primaryPurple,
                                  Color(0xFF9E8AF0),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primaryPurple
                                      .withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Icon(
                              CupertinoIcons.cloud_upload_fill,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 14),
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Upload Document',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.textPrimary,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Import PDF or image to annotate',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(
                          CupertinoIcons.xmark_circle_fill,
                          color: AppTheme.textMuted,
                          size: 24,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Divider(height: 16),

            // Scrollable Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. ALWAYS VISIBLE DOCUMENT TITLE INPUT FIELD
                    Row(
                      children: [
                        const Text(
                          'Document Title',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryPurpleLight,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'OPTIONAL',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.primaryPurpleDark,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppTheme.primaryPurple.withValues(alpha: 0.35),
                          width: 1.2,
                        ),
                      ),
                      child: TextField(
                        controller: _titleController,
                        onChanged: (val) {
                          if (val.trim().isNotEmpty) {
                            _userManuallyEditedTitle = true;
                          }
                        },
                        decoration: InputDecoration(
                          hintText:
                              'e.g., Biology Reviewer, Anatomy Chapter 1...',
                          hintStyle: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMuted,
                          ),
                          prefixIcon: const Icon(
                            CupertinoIcons.pencil,
                            size: 18,
                            color: AppTheme.primaryPurple,
                          ),
                          suffixIcon: _titleController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    CupertinoIcons.clear_circled_solid,
                                    size: 16,
                                    color: AppTheme.textMuted,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _titleController.clear();
                                      _userManuallyEditedTitle = false;
                                    });
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 14),
                        ),
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 2. Dropzone / Real Content Preview
                    if (hasFile)
                      _buildPreviewCard()
                    else
                      _buildUploadPickerArea(),

                    const SizedBox(height: 14),
                  ],
                ),
              ),
            ),

            // Bottom Upload / Open Action Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: hasFile ? _uploadAndOpenDocument : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    disabledBackgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: hasFile
                          ? const LinearGradient(
                              colors: [
                                AppTheme.primaryPurple,
                                Color(0xFF8B6DF0),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : null,
                      color: hasFile ? null : const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: hasFile
                          ? [
                              BoxShadow(
                                color: AppTheme.primaryPurple
                                    .withValues(alpha: 0.35),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ]
                          : null,
                    ),
                    child: Container(
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.arrow_up_doc_fill,
                            size: 19,
                            color: hasFile ? Colors.white : AppTheme.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Upload & Open Document',
                            style: TextStyle(
                              color:
                                  hasFile ? Colors.white : AppTheme.textMuted,
                              fontSize: 15,
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
          ],
        ),
      ),
    );
  }

  /// Initial Dropzone / Picker State
  Widget _buildUploadPickerArea() {
    return Column(
      children: [
        // Big Tap Target Box
        GestureDetector(
          onTap: _isPicking ? null : _pickFile,
          child: Container(
            width: double.infinity,
            height: 200,
            decoration: BoxDecoration(
              color: AppTheme.primaryPurpleLight.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppTheme.primaryPurple.withValues(alpha: 0.4),
                width: 1.6,
              ),
            ),
            child: Center(
              child: _isPicking
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                          color: AppTheme.primaryPurple,
                          strokeWidth: 2.5,
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Loading file preview...',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryPurpleLight,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.primaryPurple
                                    .withValues(alpha: 0.15),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: const Icon(
                            CupertinoIcons.arrow_down_doc_fill,
                            size: 30,
                            color: AppTheme.primaryPurple,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Tap to Select Document or Image',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Supported formats: PDF, PNG, JPG, JPEG, WEBP',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryPurpleLight
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Max file size: 50 MB for Cloud Sync',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primaryPurpleDark,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Quick Pick Action Chips (Files, Gallery, Camera) - Unified Single Color Palette
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isPicking ? null : _pickFile,
                icon: const Icon(CupertinoIcons.folder_fill, size: 16),
                label: const Text('Files (PDF)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryPurpleDark,
                  side: BorderSide(
                    color: AppTheme.primaryPurple.withValues(alpha: 0.35),
                  ),
                  backgroundColor:
                      AppTheme.primaryPurpleLight.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _isPicking ? null : () => _pickImage(ImageSource.gallery),
                icon: const Icon(CupertinoIcons.photo_fill, size: 16),
                label: const Text('Gallery'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryPurpleDark,
                  side: BorderSide(
                    color: AppTheme.primaryPurple.withValues(alpha: 0.35),
                  ),
                  backgroundColor:
                      AppTheme.primaryPurpleLight.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _isPicking ? null : () => _pickImage(ImageSource.camera),
                icon: const Icon(CupertinoIcons.camera_fill, size: 16),
                label: const Text('Camera'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryPurpleDark,
                  side: BorderSide(
                    color: AppTheme.primaryPurple.withValues(alpha: 0.35),
                  ),
                  backgroundColor:
                      AppTheme.primaryPurpleLight.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Selected File Preview Card
  Widget _buildPreviewCard() {
    final filePath = _selectedFilePath!;
    final fileName = _selectedFileName ?? 'Selected File';
    final fileSize = _selectedFileSize ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Document / Image Real Content Preview Container
        Container(
          width: double.infinity,
          height: 190,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.dividerColor),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(19),
            child: Stack(
              children: [
                // Real Image Content
                if (_isImage && File(filePath).existsSync())
                  Positioned.fill(
                    child: Image.file(
                      File(filePath),
                      fit: BoxFit.contain,
                    ),
                  )
                // Real PDF Page 1 Content
                else if (_pdfPage1Bytes != null)
                  Positioned.fill(
                    child: _UploadPdfPreviewImage(rawBytes: _pdfPage1Bytes!),
                  )
                // Fallback PDF Cover
                else
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            color: AppTheme.primaryPurpleLight,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            CupertinoIcons.doc_text_fill,
                            size: 34,
                            color: AppTheme.primaryPurple,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'PDF Document Ready',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatFileSize(fileSize),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Format & Size Badges
                Positioned(
                  top: 10,
                  left: 10,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _isImage ? 'IMAGE' : 'PDF DOCUMENT',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: fileSize > 50 * 1024 * 1024
                              ? const Color(0xFFF59E0B)
                              : AppTheme.primaryPurple,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              fileSize > 50 * 1024 * 1024
                                  ? CupertinoIcons.device_phone_portrait
                                  : CupertinoIcons.cloud_fill,
                              size: 11,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatFileSize(fileSize),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Clear Button
                Positioned(
                  top: 10,
                  right: 10,
                  child: GestureDetector(
                    onTap: _clearSelectedFile,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: const Icon(
                        CupertinoIcons.xmark,
                        size: 14,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),

        // File Info & Change Button
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
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
                    children: [
                      Text(
                        'Size: ${_formatFileSize(fileSize)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryPurpleDark,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        fileSize > 50 * 1024 * 1024
                            ? '• Local Storage'
                            : '• Cloud Sync Ready',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: fileSize > 50 * 1024 * 1024
                              ? const Color(0xFFD97706)
                              : const Color(0xFF16A34A),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: _pickFile,
              icon: const Icon(CupertinoIcons.arrow_2_squarepath, size: 14),
              label: const Text('Change File'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primaryPurple,
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _UploadPdfPreviewImage extends StatefulWidget {
  final Uint8List rawBytes;

  const _UploadPdfPreviewImage({required this.rawBytes});

  @override
  State<_UploadPdfPreviewImage> createState() => _UploadPdfPreviewImageState();
}

class _UploadPdfPreviewImageState extends State<_UploadPdfPreviewImage> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  void _decode() {
    ui.decodeImageFromPixels(
      widget.rawBytes,
      350,
      480,
      ui.PixelFormat.rgba8888,
      (img) {
        if (mounted) {
          setState(() {
            _image = img;
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_image != null) {
      return RawImage(image: _image, fit: BoxFit.contain);
    }
    return const Center(
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: AppTheme.primaryPurple,
      ),
    );
  }
}
