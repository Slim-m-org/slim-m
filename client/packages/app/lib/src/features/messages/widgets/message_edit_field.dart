// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline field a message row swaps in for its rendered body while being
/// edited, in place of a dialog.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../composer/widgets/composer_extras.dart'
    show MessageLengthCounter, messageLengthOverage;

/// Pre-filled with [initialContent]. Enter saves, Shift+Enter inserts a
/// newline, and Escape cancels on a hardware keyboard, with no hint row.
///
/// A soft keyboard's return key arrives through the text input channel, not
/// as a key event, so it keeps inserting a newline and Cancel and Save stay
/// drawn below the field for a thumb.
///
/// The field outlives the request: [saving] holds it read-only, and a refusal
/// arrives as [failure] with the typed text still in place. A text past the
/// message limit cannot be saved, the same rule the composer applies.
class MessageEditField extends StatefulWidget {
  const MessageEditField({
    super.key,
    required this.initialContent,
    required this.onSubmit,
    required this.onCancel,
    this.saving = false,
    this.failure,
  });

  final String initialContent;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;
  final bool saving;
  final String? failure;

  @override
  State<MessageEditField> createState() => _MessageEditFieldState();
}

class _MessageEditFieldState extends State<MessageEditField> {
  late final _controller = TextEditingController(text: widget.initialContent)
    ..selection = TextSelection.collapsed(offset: widget.initialContent.length);
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Asked for, not autofocus alone: autofocus yields to the composer when it already holds focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.saving) return;
    final text = _controller.text.trim();
    // An edit down to nothing is a cancel, not a delete: this field has no
    // way to delete the message, so it must leave the original untouched.
    if (text.isEmpty) {
      widget.onCancel();
    } else if (messageLengthOverage(_controller.text.runes.length) == null) {
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
              readOnly: widget.saving,
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
            if (widget.failure case final failure?)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s8),
                child: AppErrorState(
                  message: failure,
                  onRetry: _submit,
                  retryLabel: 'Try again',
                ),
              ),
            const SizedBox(height: AppSpacing.s4),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) => _Footer(
                length: value.text.runes.length,
                saving: widget.saving,
                onCancel: widget.onCancel,
                onSave: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The length counter, then the Cancel and Save buttons, under the field.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.length,
    required this.saving,
    required this.onCancel,
    required this.onSave,
  });

  final int length;
  final bool saving;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        MessageLengthCounter(length: length),
        const Spacer(),
        Row(
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
              busy: saving,
              disabled: messageLengthOverage(length) != null,
              onPressed: onSave,
            ),
          ],
        ),
      ],
    );
  }
}
