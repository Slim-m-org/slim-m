// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The draft's preview at the top of the theme editor's column. On a page
/// tall enough it stays pinned, folding its extra rows away as the column
/// scrolls under it, so the colours keep most of the page.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_draft.dart';
import 'theme_miniature.dart';

class ThemeEditorPreview extends StatelessWidget {
  const ThemeEditorPreview({
    super.key,
    required this.draft,
    required this.scroll,
    required this.inset,
    required this.roomy,
    required this.pinned,
  });

  final ThemeDraft draft;

  /// The column's controller; how far it has scrolled is how far the
  /// preview has folded.
  final ScrollController scroll;
  final double inset;

  /// The full draft with its channel list; the short strip when false.
  final bool roomy;

  /// Pinned and folding; when false it scrolls away whole.
  final bool pinned;

  static const previewKey = Key('theme-editor-preview');

  @override
  Widget build(BuildContext context) {
    if (!pinned) return SliverToBoxAdapter(child: _framed(context, open: 1));
    return SliverResizingHeader(
      minExtentPrototype: _framed(context, open: 0, live: false),
      maxExtentPrototype: _framed(context, open: 1, live: false),
      child: LayoutBuilder(
        builder: (context, box) {
          final scrolled = scroll.hasClients
              ? math.max(0.0, scroll.offset)
              : 0.0;
          // The header hands its folded height down as the minimum.
          final room = box.maxHeight - box.minHeight;
          return _framed(
            context,
            open: room <= 0 ? 0 : room / (room + scrolled),
            under: scrolled > 0,
          );
        },
      ),
    );
  }

  /// [live] repaints with the draft; a prototype only measures a height.
  Widget _framed(
    BuildContext context, {
    required double open,
    bool live = true,
    bool under = false,
  }) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final vertical = inset > AppSpacing.s16 ? AppSpacing.s16 : AppSpacing.s12;
    final detail = roomy
        ? ThemeMiniatureDetail.draft
        : ThemeMiniatureDetail.draftStrip;
    final framed = DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, vertical, inset, vertical),
        child: AppContentColumn(
          child: live
              ? ListenableBuilder(
                  listenable: draft,
                  builder: (_, _) => ThemeMiniature.forDocument(
                    draft.document,
                    key: previewKey,
                    detail: detail,
                    open: open,
                  ),
                )
              : ThemeMiniature.forDocument(
                  draft.document,
                  detail: detail,
                  open: open,
                ),
        ),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        framed,
        if (under)
          Positioned(
            left: 0,
            right: 0,
            bottom: -_Fade.height,
            height: _Fade.height,
            child: _Fade(colour: tokens.surfaceBase),
          ),
      ],
    );
  }
}

/// Softens the rows that slide under the pinned preview.
class _Fade extends StatelessWidget {
  const _Fade({required this.colour});

  final Color colour;

  static const height = AppSpacing.s12;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox(
      key: const Key('theme-editor-preview-fade'),
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colour, colour.withValues(alpha: 0)],
          ),
        ),
      ),
    ),
  );
}
