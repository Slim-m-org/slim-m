// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's code flows: the code action's picker, and the offer to
/// turn a pasted chunk of code into a fenced block. Kept out of
/// `composer.dart`, which has no line budget left.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_code_fence.dart';
import 'composer_code_guess.dart';
import 'composer_code_picker.dart';
import 'composer_markdown_shortcuts.dart' show wrapSelectionWithMarker;
import '../../../widgets/text_insert.dart';

/// Opens the picker and inserts what was chosen at the selection.
Future<void> insertCodeFromPicker(
  BuildContext context,
  TextEditingController controller,
  FocusNode focus,
) async {
  final selection = controller.selection;
  final selected = selection.isValid
      ? selection.textInside(controller.text)
      : '';
  final choice = await showCodeInsertPicker(
    context,
    allowInline: !selected.contains('\n'),
  );
  if (choice == null) return;
  focus.requestFocus();
  final value = controller.value.copyWith(selection: selection);
  controller.value = value;
  if (!choice.isInline) {
    controller.value = insertCodeFence(value, language: choice.language!);
  } else if (selected.isEmpty) {
    insertAtSelection(controller, '``', caretOffset: 1);
  } else {
    controller.value = wrapSelectionWithMarker(value, '`');
  }
}

/// A pasted chunk that reads as code, still sitting where it was pasted.
class CodePaste {
  const CodePaste(this.start, this.end, this.language);

  final int start;
  final int end;

  /// `''` when no language could be told.
  final String language;
}

/// Watches the field for a paste that reads as code. A paste is told apart
/// from typing by its size (several lines in one edit) and from a draft
/// restore by the caret, which a paste leaves at the end of what it put in
/// and `controller.text =` does not.
class ComposerCodePaste extends ChangeNotifier {
  ComposerCodePaste(this._controller) : _last = _controller.value {
    _controller.addListener(_onChange);
  }

  final TextEditingController _controller;
  TextEditingValue _last;
  CodePaste? _offer;

  CodePaste? get offer => _offer;

  void _onChange() {
    final before = _last;
    final now = _controller.value;
    _last = now;
    if (before.text == now.text) return;
    _set(_pasteIn(before.text, now));
  }

  CodePaste? _pasteIn(String before, TextEditingValue now) {
    final text = now.text;
    final shorter = before.length < text.length ? before.length : text.length;
    var head = 0;
    while (head < shorter && before.codeUnitAt(head) == text.codeUnitAt(head)) {
      head++;
    }
    var tail = 0;
    while (tail < shorter - head &&
        before.codeUnitAt(before.length - 1 - tail) ==
            text.codeUnitAt(text.length - 1 - tail)) {
      tail++;
    }
    final end = text.length - tail;
    final inserted = text.substring(head, end);
    if (!inserted.contains('\n') || now.selection.baseOffset != end) {
      return null;
    }
    final atHead = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: head),
    );
    if (caretInOpenFence(atHead)) return null;
    final language = guessPastedCode(inserted);
    return language == null ? null : CodePaste(head, end, language);
  }

  void _set(CodePaste? next) {
    if (next == null && _offer == null) return;
    _offer = next;
    notifyListeners();
  }

  void dismiss() => _set(null);

  /// Wraps the pasted chunk in a fence; the caret ends after the block.
  void convert() {
    final offer = _offer;
    if (offer == null) return;
    _offer = null;
    _controller.value = insertCodeFence(
      _controller.value.copyWith(
        selection: TextSelection(
          baseOffset: offer.start,
          extentOffset: offer.end,
        ),
      ),
      language: offer.language,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    super.dispose();
  }
}

/// The one-tap offer above the field after a code paste.
class ComposerCodePasteOffer extends StatelessWidget {
  const ComposerCodePasteOffer({super.key, required this.paste});

  final ComposerCodePaste paste;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: paste,
    builder: (context, _) {
      final offer = paste.offer;
      return AppRevealBand(
        child: offer == null ? null : _OfferBand(offer: offer, paste: paste),
      );
    },
  );
}

class _OfferBand extends StatelessWidget {
  const _OfferBand({required this.offer, required this.paste});

  final CodePaste offer;
  final ComposerCodePaste paste;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final language = offer.language.isEmpty
        ? null
        : CodeInsertChoice.block(offer.language).label;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s12,
          AppSpacing.s4,
          AppSpacing.s4,
          AppSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Row(
          spacing: AppSpacing.s8,
          children: [
            Icon(
              AppIcons.codeBlock,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            Expanded(
              child: Text(
                language == null
                    ? 'That looks like code.'
                    : 'That looks like $language.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            AppButton(
              label: 'Format as code block',
              size: AppButtonSize.sm,
              onPressed: paste.convert,
            ),
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Keep as text',
              tooltip: 'Keep as text',
              size: AppIconButtonSize.sm,
              iconSize: AppSizes.icon16,
              onPressed: paste.dismiss,
            ),
          ],
        ),
      ),
    );
  }
}
