// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The editor's first card: the theme's name, its mode, and the theme its
/// colours started from.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/my_themes.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_store.dart';
import 'settings_control_column.dart';
import 'settings_field.dart';
import 'settings_section_header.dart';
import 'settings_segmented_row.dart';
import 'settings_select_row.dart';
import 'theme_editor_menu.dart';
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
    final doc = draft.document;
    return SettingsSectionCard(
      key: const Key('theme-editor-details'),
      title: 'Details',
      topGap: 0,
      children: [
        SettingsCardBlock(
          children: [
            SettingsField(
              label: 'Name',
              child: AppInput(
                key: const Key('theme-editor-name'),
                controller: name,
                semanticLabel: 'Theme name',
                counterMax: themeNameMaxChars,
                errorText: draft.nameValid
                    ? null
                    : 'Use 1 to $themeNameMaxChars characters.',
                onChanged: draft.setName,
              ),
            ),
          ],
        ),
        SettingsControlColumn(
          child: SettingsSegmentedRow<Brightness>(
            label: 'Mode',
            description: 'Sets scrollbars and system menus, not colours.',
            value: doc.brightness,
            choices: const [
              SettingsChoice(value: Brightness.dark, label: 'Dark'),
              SettingsChoice(value: Brightness.light, label: 'Light'),
            ],
            onChanged: draft.setBrightness,
          ),
        ),
        SettingsControlColumn(child: _startFrom(ref)),
      ],
    );
  }

  Widget _startFrom(WidgetRef ref) {
    final sources = themeEditorSources(
      mine: ref.watch(myThemesProvider),
      space: ref.watch(spaceThemesProvider).valueOrNull?.themes ?? const [],
    );
    final from = draft.startedFrom;
    final known = sources.any((s) => s.key == from);
    return SettingsSelectRow<String>(
      key: const Key('theme-editor-start-from'),
      label: 'Start from',
      description: 'Keeps your name.',
      sheetTitle: 'Start from',
      value: known ? from : 'base:${draft.document.base}',
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
