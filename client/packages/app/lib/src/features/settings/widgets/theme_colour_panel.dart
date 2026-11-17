// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker for one theme colour, with what it also sets, a live contrast
/// line and, for a see-through colour, its opacity: inline in a wide editor,
/// a titled sheet on a phone (rule 4 of `docs/design/desktop-vs-mobile.md`).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_draft.dart';
import '../providers/theme_links.dart';
import '../providers/theme_picker_check.dart';
import 'theme_opacity_slider.dart';

/// Opens [token]'s picker as a sheet. Done keeps the colour; Cancel or a
/// dismiss puts the draft back as it was, links included.
Future<void> showThemeColourSheet(
  BuildContext context,
  ThemeDraft draft,
  String token,
) async {
  final mark = draft.mark();
  final picked = await showAppColourPicker(
    context,
    initial: draft.document.colours[token]!.withValues(alpha: 1),
    title: themeTokenLabels[token]!,
    caption: themeLinkNote(draft.links, token),
    confirmLabel: 'Done',
    onChanged: (c) => draft.setColour(token, c),
    extraBuilder: (context, colour) =>
        _ThemeColourExtras(draft: draft, token: token, colour: colour),
  );
  if (picked == null) {
    draft.restore(mark);
  } else {
    draft.setColour(token, picked);
  }
}

/// The inline picker: the square and hue beside the hex field, the extras
/// and the buttons, so it stays short under the pinned preview.
class ThemeColourPanel extends StatelessWidget {
  const ThemeColourPanel({
    super.key,
    required this.draft,
    required this.token,
    required this.note,
    required this.onDone,
    required this.onCancel,
  });

  final ThemeDraft draft;
  final String token;

  /// What changing it also sets, as it stood when the picker opened.
  final String? note;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => AppColourPicker(
    key: Key('theme-picker-$token'),
    beside: true,
    initial: draft.document.colours[token]!.withValues(alpha: 1),
    confirmLabel: 'Done',
    confirmVariant: AppButtonVariant.secondary,
    onChanged: (c) => draft.setColour(token, c),
    extraBuilder: (context, colour) => _ThemeColourExtras(
      draft: draft,
      token: token,
      colour: colour,
      note: note,
    ),
    onSave: (c) {
      draft.setColour(token, c);
      onDone();
    },
    onCancel: onCancel,
  );
}

/// The lines under or beside the picker: the live contrast verdict, the
/// linked note, and the opacity slider of a see-through colour.
class _ThemeColourExtras extends StatelessWidget {
  const _ThemeColourExtras({
    required this.draft,
    required this.token,
    required this.colour,
    this.note,
  });

  final ThemeDraft draft;
  final String token;

  /// The colour as the picker holds it this moment.
  final Color colour;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final check = themePickerCheck({
      ...draft.document.colours,
      token: colour.withValues(alpha: draft.document.colours[token]!.a),
    }, token);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s12,
      children: [
        if (check != null)
          _Line(
            key: const Key('theme-picker-check'),
            icon: check.passes ? AppIcons.check : AppIcons.warning,
            warn: !check.passes,
            text: check.text,
          ),
        if (note != null)
          _Line(
            key: const Key('theme-picker-note'),
            icon: AppIcons.linkedColour,
            text: note!,
          ),
        if (themeAlphaTokens.contains(token))
          ListenableBuilder(
            listenable: draft,
            builder: (context, _) => ThemeOpacitySlider(
              sliderKey: Key('theme-picker-opacity-$token'),
              token: token,
              value: draft.document.colours[token]!.a,
              onChanged: (v) => draft.setOpacity(token, v),
            ),
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.icon,
    required this.text,
    this.warn = false,
  });

  final IconData icon;
  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final colour = warn ? tokens.warnText : tokens.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s8,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: AppSizes.icon16, color: colour),
        ),
        Expanded(
          child: Text(text, style: AppText.caption.copyWith(color: colour)),
        ),
      ],
    );
  }
}
