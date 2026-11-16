// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small chat window painted with the theme being edited, so every token
/// shows up somewhere before the theme is saved.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_miniature.dart';

class ThemeEditorPreview extends StatelessWidget {
  const ThemeEditorPreview({
    super.key,
    required this.document,
    this.compact = false,
  });

  final ThemeDocument document;

  /// Drops the sidebar and the second message for a phone's short strip.
  final bool compact;

  @override
  Widget build(BuildContext context) => ThemeMiniature.forDocument(
    document,
    key: const Key('theme-editor-preview'),
    detail: compact
        ? ThemeMiniatureDetail.draftStrip
        : ThemeMiniatureDetail.draft,
  );
}
