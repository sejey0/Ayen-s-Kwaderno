import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/handwriting_note_model.dart';
import '../services/document_storage_service.dart';
import '../theme/app_theme.dart';

/// Modal dialog for creating typed notes with customizable title and palette
class TypeNoteDialog extends StatefulWidget {
  final HandwritingNote? existingNote;

  const TypeNoteDialog({super.key, this.existingNote});

  /// Static helper to launch TypeNoteDialog
  static Future<HandwritingNote?> show(BuildContext context,
      {HandwritingNote? existingNote}) {
    return showModalBottomSheet<HandwritingNote>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (context) => TypeNoteDialog(existingNote: existingNote),
    );
  }

  @override
  State<TypeNoteDialog> createState() => _TypeNoteDialogState();
}

class _TypeNoteDialogState extends State<TypeNoteDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  int _selectedPaletteIndex = 0;

  @override
  void initState() {
    super.initState();
    if (widget.existingNote != null) {
      _titleController.text = widget.existingNote!.title;
      _contentController.text = widget.existingNote!.content;
      _selectedPaletteIndex = widget.existingNote!.paletteIndex;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _saveTypedNote() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter content for your note.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final title = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : 'Note ${DateTime.now().month}/${DateTime.now().day}';

    final note = HandwritingNote(
      id: widget.existingNote?.id ??
          'note_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      content: content,
      createdAt: widget.existingNote?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      paletteIndex: _selectedPaletteIndex,
      isCloudSynced: false,
      isHandwritten: false,
    );

    await DocumentStorageService.saveOrUpdateHandwritingNote(note);

    if (!mounted) return;
    Navigator.of(context).pop(note);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75 + bottomInset,
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
                                  AppTheme.accentPink,
                                  Color(0xFFFF8DA1),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              CupertinoIcons.keyboard,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Type Study Note',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              Text(
                                'Digital sticky note with auto-sync',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppTheme.textSecondary,
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

            const Divider(height: 12),

            // Note Title Input
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.dividerColor),
                ),
                child: TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    hintText: 'Note Title (e.g. Formula Sheet, Quick Task)...',
                    hintStyle:
                        TextStyle(fontSize: 13, color: AppTheme.textMuted),
                    prefixIcon: Icon(
                      CupertinoIcons.pencil,
                      size: 16,
                      color: AppTheme.accentPink,
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
            ),
            const SizedBox(height: 10),

            // Main Typed Text Content Editor
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: AppTheme.accentPink.withValues(alpha: 0.35),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: TextField(
                    controller: _contentController,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText:
                          'Type your study notes, equations, or key reminders here...',
                      hintStyle:
                          TextStyle(fontSize: 13.5, color: AppTheme.textMuted),
                      border: InputBorder.none,
                    ),
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ),
            ),

            // Bottom Save Action Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _saveTypedNote,
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
                          AppTheme.accentPink,
                          Color(0xFFFF8DA1),
                          AppTheme.primaryPurple,
                        ],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.accentPink.withValues(alpha: 0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Container(
                      alignment: Alignment.center,
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.checkmark_alt_circle_fill,
                            color: Colors.white,
                            size: 19,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Save Note',
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
            ),
          ],
        ),
      ),
    );
  }
}
