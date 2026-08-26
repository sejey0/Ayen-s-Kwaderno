import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/document_item_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';
import '../screens/editor_screen.dart';

/// Modal bottom sheet for uploading and previewing PDF documents or images
class UploadDocumentDialog extends StatefulWidget {
  const UploadDocumentDialog({super.key});

  /// Static helper to launch the dialog
  static Future<DocumentItem?> show(BuildContext context) {
    return showModalBottomSheet<DocumentItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
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
        _processSelectedFile(picked.path!, picked.name);
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
        _processSelectedFile(photo.path, photo.name);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPicking = false);
      _showErrorSnackBar('Unable to pick image: $e');
    }
  }

  void _processSelectedFile(String path, String name) {
    final file = File(path);
    final size = file.existsSync() ? file.lengthSync() : 0;
    final lower = path.toLowerCase();
    final isImg = lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');

    setState(() {
      _selectedFilePath = path;
      _selectedFileName = name;
      _selectedFileSize = size;
      _isImage = isImg;
      if (_titleController.text.trim().isEmpty) {
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
      _titleController.clear();
    });
  }

  Future<void> _uploadAndOpenDocument() async {
    if (_selectedFilePath == null) return;

    final filePath = _selectedFilePath!;
    final customName = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : (_selectedFileName ?? 'Document');

    // Create & persist DocumentItem
    final newDoc = DocumentItem(
      fileName: customName,
      filePath: filePath,
      lastOpenedAt: DateTime.now(),
      annotationsCount: 0,
      paletteIndex: DateTime.now().millisecond % 6,
      isCloudSynced: false,
    );

    await DocumentStorageService.saveOrUpdateDocument(newDoc);

    if (!mounted) return;
    Navigator.of(context).pop(newDoc);

    // Navigate to Editor
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EditorScreen(
          pdfPath: filePath,
          fileName: customName,
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
      height: MediaQuery.of(context).size.height * 0.72 + bottomInset,
      decoration: const BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
      ),
      child: Column(
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
                const SizedBox(height: 12),

                // Title Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                AppTheme.primaryPurple,
                                AppTheme.accentPink,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            CupertinoIcons.cloud_upload_fill,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Upload Document or Image',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                            Text(
                              'Preview file before opening in editor',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.textSecondary,
                                fontWeight: FontWeight.w500,
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

          // Main Content: Upload Area or File Preview
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: hasFile ? _buildPreviewCard() : _buildUploadPickerArea(),
            ),
          ),

          // Bottom Upload / Open Action Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SizedBox(
              width: double.infinity,
              height: 50,
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
                              Color(0xFF9E8AF0),
                              AppTheme.accentPink,
                            ],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          )
                        : null,
                    color: hasFile ? null : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: hasFile
                        ? [
                            BoxShadow(
                              color: AppTheme.primaryPurple
                                  .withValues(alpha: 0.35),
                              blurRadius: 10,
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
                          size: 18,
                          color: hasFile ? Colors.white : AppTheme.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Upload & Open Document',
                          style: TextStyle(
                            color: hasFile ? Colors.white : AppTheme.textMuted,
                            fontSize: 14.5,
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
    );
  }

  /// Initial Dropzone / Picker State
  Widget _buildUploadPickerArea() {
    return Column(
      children: [
        // Big Tap Target Box
        Expanded(
          child: GestureDetector(
            onTap: _isPicking ? null : _pickFile,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.primaryPurple.withValues(alpha: 0.4),
                  width: 1.6,
                  style: BorderStyle.solid,
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
                            'Selecting file...',
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
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: AppTheme.primaryPurpleLight,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              CupertinoIcons.arrow_down_doc_fill,
                              size: 32,
                              color: AppTheme.primaryPurple,
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Tap to Select Document or Image',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Supported formats: PDF, PNG, JPG, JPEG, WEBP',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Quick Pick Action Chips (Files, Gallery, Camera)
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isPicking ? null : _pickFile,
                icon: const Icon(CupertinoIcons.folder, size: 16),
                label: const Text('Files (PDF)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryPurpleDark,
                  side: const BorderSide(color: AppTheme.primaryPurpleLight),
                  backgroundColor: AppTheme.primaryPurpleLight.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isPicking ? null : () => _pickImage(ImageSource.gallery),
                icon: const Icon(CupertinoIcons.photo, size: 16),
                label: const Text('Gallery'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accentPinkDark,
                  side: const BorderSide(color: AppTheme.accentPinkLight),
                  backgroundColor: AppTheme.accentPinkLight.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isPicking ? null : () => _pickImage(ImageSource.camera),
                icon: const Icon(CupertinoIcons.camera, size: 16),
                label: const Text('Camera'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Color(0xFF0284C7),
                  side: const BorderSide(color: Color(0xFFBAE6FD)),
                  backgroundColor: Color(0xFFE0F2FE).withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
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

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Document / Image Preview Container
          Container(
            width: double.infinity,
            height: 180,
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: Stack(
                children: [
                  if (_isImage && File(filePath).existsSync())
                    Positioned.fill(
                      child: Image.file(
                        File(filePath),
                        fit: BoxFit.contain,
                      ),
                    )
                  else
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
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

                  // Format Badge
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
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
                  ),

                  // Clear / Change Button
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
          const SizedBox(height: 14),

          // File Info & Change Action
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
                    const SizedBox(height: 2),
                    Text(
                      _formatFileSize(fileSize),
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _pickFile,
                icon: const Icon(CupertinoIcons.arrow_2_squarepath, size: 14),
                label: const Text('Change'),
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
          const SizedBox(height: 10),

          // Custom Document Title Field
          const Text(
            'Document Title',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                hintText: 'Enter title for notebook cover...',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: AppTheme.textMuted,
                ),
                prefixIcon: Icon(
                  CupertinoIcons.pencil,
                  size: 16,
                  color: AppTheme.primaryPurple,
                ),
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
