// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline field a message row swaps in for its rendered body while being
/// edited, in place of a dialog.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

/// Pre-filled with [initialContent]. Enter saves, Shift+Enter inserts a
/// newline, and Escape cancels on a hardware keyboard, with no hint row.
///
/// A soft keyboard's return key arrives through the text input channel, not
/// as a key event, so it keeps inserting a newline and Cancel and Save stay
/// drawn below the field for a thumb.
class MessageEditField extends StatefulWidget {
  const MessageEditField({
    super.key,
    required this.initialContent,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initialContent;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  @override
  State<MessageEditField> createState() => _MessageEditFieldState();
}

class _MessageEditFieldState extends State<MessageEditField> {
  late final _controller = TextEditingController(text: widget.initialContent);
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    // An edit down to nothing is a cancel, not a delete: this field has no
    // way to delete the message, so it must leave the original untouched.
    if (text.isEmpty) {
      widget.onCancel();
    } else {
      widget.onSubmit(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s8,
          vertical: AppSpacing.s4,
        ),
        decoration: BoxDecoration(
          // The row around it is raised while editing, so the field sits in it as an inset.
          color: tokens.surfaceBase,
          border: Border.all(color: tokens.accentFill),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              minLines: 1,
              maxLines: 10,
              style: AppText.body.copyWith(color: tokens.textPrimary),
              cursorColor: tokens.accent,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                // Opts out of the global boxed-input theme; the surrounding
                // widget draws its own chrome.
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            _Footer(onCancel: widget.onCancel, onSave: _submit),
          ],
        ),
      ),
    );
  }
}

/// The Cancel and Save buttons under the field.
class _Footer extends StatelessWidget {
  const _Footer({required this.onCancel, required this.onSave});

  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s8,
        children: [
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.sm,
            onPressed: onCancel,
          ),
          AppButton(
            label: 'Save',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.sm,
            onPressed: onSave,
          ),
        ],
      ),
    );
  }
}
