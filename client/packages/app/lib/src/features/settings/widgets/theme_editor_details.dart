// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The editor's first card: the theme's name, its mode, and the theme its
/// colours started from.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_draft.dart';
import '../providers/theme_editor_sources.dart';
import 'settings_control_column.dart';
import 'settings_section_header.dart';
import 'settings_segmented_row.dart';
import 'settings_select_row.dart';
import 'theme_draft_select.dart';
import 'theme_miniature_thumb.dart';

class ThemeEditorDetails extends ConsumerWidget {
  const ThemeEditorDetails({
    super.key,
    required this.draft,
    required this.name,
    required this.onStartFrom,
  });

  final ThemeDraft draft;
  final TextEditingController name;

  /// Runs once a choice replaces the colours, so an open picker can close.
  final VoidCallback onStartFrom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(themeEditorSourcesProvider);
    return ThemeDraftSelect(
      draft: draft,
      select: (d) => (
        nameValid: d.nameValid,
        brightness: d.document.brightness,
        startedFrom: d.startedFrom,
        base: d.document.base,
      ),
      builder: (context, shown) => SettingsSectionCard(
        key: const Key('theme-editor-details'),
        title: 'Details',
        topGap: 0,
        children: [
          _NameField(
            input: AppInput(
              key: const Key('theme-editor-name'),
              controller: name,
              semanticLabel: 'Theme name',
              counterMax: themeNameMaxChars,
              errorText: shown.nameValid
                  ? null
                  : 'Use 1 to $themeNameMaxChars characters.',
              onChanged: draft.setName,
            ),
          ),
          SettingsControlColumn(
            child: SettingsSegmentedRow<Brightness>(
              label: 'Mode',
              description: 'Sets scrollbars and system menus, not colours.',
              value: shown.brightness,
              choices: const [
                SettingsChoice(value: Brightness.dark, label: 'Dark'),
                SettingsChoice(value: Brightness.light, label: 'Light'),
              ],
              onChanged: draft.setBrightness,
            ),
          ),
          SettingsControlColumn(
            child: _startFrom(sources, shown.startedFrom, shown.base),
          ),
        ],
      ),
    );
  }

  Widget _startFrom(List<ThemeEditorSource> sources, String from, String base) {
    final known = sources.any((s) => s.key == from);
    return SettingsSelectRow<String>(
      key: const Key('theme-editor-start-from'),
      label: 'Start from',
      description: 'Keeps your name.',
      sheetTitle: 'Start from',
      value: known ? from : 'base:$base',
      choices: [
        for (final s in sources)
          SettingsChoice(
            value: s.key,
            label: s.label,
            leading: ThemeMiniatureThumb.forDocument(s.document),
          ),
      ],
      onChanged: (key) {
        final source = sources.firstWhere((s) => s.key == key);
        onStartFrom();
        draft.startFrom(source.document, key: source.key);
      },
    );
  }
}

/// What [AppInput] keeps outside its border for the focus ring.
const _inputRing = AppSpacing.s4;

/// The name and its field, the field's border on the card's inset like the
/// Mode and Start from controls under it.
class _NameField extends StatelessWidget {
  const _NameField({required this.input});

  final Widget input;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16 - _inputRing,
        vertical: AppSpacing.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: _inputRing),
            child: Text(
              'Name',
              style: AppText.caption.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.medium,
              ),
            ),
          ),
          input,
        ],
      ),
    );
  }
}
