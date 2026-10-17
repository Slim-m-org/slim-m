// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette's compact-width shell: pattern pair 3 in
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

/// [searchField] and [results] are built by `command_palette.dart` itself,
/// so the search state, the result ranking and every row stay the one shared
/// implementation; this widget only ever decides how they are framed.
class CommandPaletteCompactShell extends StatelessWidget {
  const CommandPaletteCompactShell({
    super.key,
    required this.searchField,
    required this.results,
    required this.onCancel,
  });

  final Widget searchField;
  final Widget results;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Align(
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
                const AppMenuDivider(),
                results,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
