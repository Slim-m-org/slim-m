// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The note tool's own sheet: text entered here, and only here, is what a
/// placed note ever carries.
///
/// There is no in-place edit anywhere on this canvas - a stroke's ink cannot
/// be redrawn, an image's bytes cannot be swapped - so a note follows the
/// same rule and is never edited after placement. That is what makes this
/// sheet the one and only place a note's text is ever typed, and why a note
/// never appears on the shared canvas mid-composition: nothing is sent until
/// this sheet's own submit, so there is nothing for another participant to
/// see somebody "typing into".
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

/// The exact wire cost of a note's `props`: `text` JSON-escaped inside
/// `{"text":"..."}` and UTF-8 encoded, the same bytes the server's
/// `MAX_PROPS_BYTES` counts.
///
/// A *character* count was tried first and was wrong: `serde_json` (server
/// side) and `jsonEncode` (here) both leave any non-ASCII byte unescaped, so
/// a character costing more than one UTF-8 byte - ordinary CJK text, for
/// one, not a hostile string - costs that many wire bytes per unit of a
/// character count. 1800 CJK characters is 5,412 wire bytes, already over
/// the server's 4 KiB ceiling; only a control character's `\u00XX` escape is
/// worse, at 6 bytes each. Measuring the real encoded size is what a length
/// limit means here, not an approximation of it.
int noteWireBytes(String text) =>
    utf8.encode(jsonEncode({'text': text})).length;

/// A comfortable margin under the server's `MAX_PROPS_BYTES` (4 KiB), leaving
/// room for the request's own envelope fields alongside `props`.
const int maxNoteTextBytes = 4000;

/// Refuses an edit that would push [noteWireBytes] over [maxBytes], rather
/// than truncating mid-character: reverting to the last value that fit is
/// simple and can never split a surrogate pair or a grapheme cluster the way
/// slicing a string at a computed cut point could.
class _NoteByteLimitFormatter extends TextInputFormatter {
  const _NoteByteLimitFormatter(this.maxBytes);

  final int maxBytes;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (noteWireBytes(newValue.text) <= maxBytes) return newValue;
    return oldValue;
  }
}

/// Opens the note sheet and answers with the entered text, or null if the
/// person cancelled without typing anything worth keeping.
Future<String?> showCanvasNoteSheet(BuildContext context) {
  return showAppSheet<String?>(
    context,
    builder: (context) => const _CanvasNoteSheet(),
  );
}

class _CanvasNoteSheet extends StatefulWidget {
  const _CanvasNoteSheet();

  @override
  State<_CanvasNoteSheet> createState() => _CanvasNoteSheetState();
}

class _CanvasNoteSheetState extends State<_CanvasNoteSheet> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canSubmit => _text.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(_text.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add a note',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          Container(
            decoration: BoxDecoration(
              color: tokens.surfaceBase,
              border: Border.all(color: tokens.borderSubtle),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s12,
              vertical: AppSpacing.s8,
            ),
            child: TextField(
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              inputFormatters: const [
                _NoteByteLimitFormatter(maxNoteTextBytes),
              ],
              style: AppText.body.copyWith(color: tokens.textPrimary),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: 'What do you want to remember?',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: 'Add note',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: !_canSubmit,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
