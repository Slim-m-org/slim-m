// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette's frames: [CommandPaletteFrame] picks the floating card
/// or, below `kCompactWidth`, the compact-width shell, pattern pair 3 in
/// `docs/design/desktop-vs-mobile.md` ("Command palette -> pull-down").
///
/// Below `kCompactWidth` the floating card `command_palette.dart` draws for
/// a pointer becomes a full-bleed panel pinned to the top of the window
/// instead: the same search field and results list, without the card's own
/// fixed width, border and shadow, and with an on-screen Cancel button
/// standing in for Escape - a touch device has no key for that at all, and
/// the keyboard-hint footer the floating card shows would be explaining keys
/// that are not there.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The compact search row: the field beside an on-screen Cancel, over a
/// hairline.
class _CompactSearchRow extends StatelessWidget {
  const _CompactSearchRow({
    required this.searchField,
    required this.onCancel,
    this.divider = true,
  });

  final Widget searchField;
  final VoidCallback onCancel;

  /// Whether the row draws its own inset hairline; chips below take its place.
  final bool divider;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s12,
          AppSpacing.s8,
          AppSpacing.s8,
          AppSpacing.s8,
        ),
        child: Row(
          children: [
            Expanded(child: searchField),
            const SizedBox(width: AppSpacing.s8),
            AppButton(
              key: const Key('command-palette-cancel'),
              label: 'Cancel',
              variant: AppButtonVariant.ghost,
              touch: true,
              onPressed: onCancel,
            ),
          ],
        ),
      ),
      if (divider) const AppMenuDivider(),
    ],
  );
}

/// [searchField] and [results] are built by `command_palette.dart` itself,
/// so the search state, the result ranking and every row stay the one shared
/// implementation; this widget only ever decides how they are framed.
class CommandPaletteCompactShell extends StatelessWidget {
  const CommandPaletteCompactShell({
    super.key,
    required this.searchField,
    required this.results,
    required this.onCancel,
    this.chips,
  });

  final Widget searchField;

  /// The search's filters, under the field and its Cancel rather than beside Cancel.
  final Widget? chips;
  final Widget results;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    // The panel ends at an on-screen keyboard, so no result sits under it.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border(bottom: BorderSide(color: tokens.borderStrong)),
          ),
          child: SafeArea(
            bottom: false,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CompactSearchRow(
                    searchField: searchField,
                    onCancel: onCancel,
                    divider: chips == null,
                  ),
                  if (chips case final chips?) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.s12,
                        0,
                        AppSpacing.s12,
                        AppSpacing.s8,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: chips,
                      ),
                    ),
                    const AppMenuDivider(),
                  ],
                  Flexible(child: results),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The design's floating card width; not on the spacing grid because it is
/// the palette's own measured size, like the rail widths beside it. Only
/// reached at or above `kCompactWidth`, where the window is always wider.
const double _paletteWidth = 600;

/// The palette framed for the window's width: the floating card at or above
/// `kCompactWidth`, [CommandPaletteCompactShell] below it, the same field,
/// chips and results in both.
class CommandPaletteFrame extends StatelessWidget {
  const CommandPaletteFrame({
    super.key,
    required this.compact,
    required this.input,
    required this.results,
    required this.footer,
    required this.onCancel,
    this.chips,
  });

  final bool compact;
  final Widget input;
  final Widget? chips;
  final Widget results;

  /// The keyboard hints, which only the card shows: a touch screen has no keys.
  final Widget footer;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return CommandPaletteCompactShell(
        searchField: input,
        chips: chips,
        results: results,
        onCancel: onCancel,
      );
    }
    return Align(
      alignment: const Alignment(0, -0.5),
      child: Material(
        type: MaterialType.transparency,
        child: AppMenu(
          width: _paletteWidth,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: AppSpacing.s8,
                children: [input, ?chips],
              ),
            ),
            const AppMenuDivider(),
            results,
            const AppMenuDivider(),
            footer,
          ],
        ),
      ),
    );
  }
}
