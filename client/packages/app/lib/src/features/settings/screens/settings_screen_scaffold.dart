// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The frame every settings and administration screen sits in.
///
/// Eight screens carried this verbatim, down to the same one-line comment
/// explaining the `top: false`. That is not only duplication: it is eight
/// chances for one screen to drift into a different content width, lose its
/// safe-area inset, or forget the comment's reasoning and "fix" the inset
/// back on. Named once, a change to the frame is one edit.
///
/// Deliberately in `screens/` rather than the design system: it knows this
/// app's routes (through [BackToButton]) and its content column, which a
/// component library has no business knowing.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/close_screen.dart';

class SettingsScreenScaffold extends StatelessWidget {
  const SettingsScreenScaffold({
    super.key,
    required this.title,
    required this.backTooltip,
    required this.backFallback,
    required this.child,
    this.actions,
    this.onBack,
    this.scrollable = true,
    this.padding = const EdgeInsets.all(AppSpacing.s16),
  });

  final String title;

  /// Names the destination, not just "Back": the tooltip is the only thing
  /// that says where the button goes. See [BackToButton].
  final String backTooltip;
  final String backFallback;

  final List<Widget>? actions;

  /// Replaces leaving the screen, for a screen with an inner page to step out of first.
  final VoidCallback? onBack;

  /// The body. Wrapped in a scrolling list by default, since these screens
  /// are lists of rows; false for a body that scrolls itself (or must not).
  final Widget child;
  final bool scrollable;
  final EdgeInsets padding;

  // The home-indicator inset is scroll padding, so content passes under it instead of stopping at an empty band.
  Widget _body(BuildContext context) {
    final inset =
        padding + EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom);
    return scrollable
        ? ListView(
            key: const Key('settings-scaffold-list'),
            padding: inset,
            children: [child],
          )
        : Padding(padding: inset, child: child);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title),
      leading: BackToButton(
        tooltip: backTooltip,
        fallback: backFallback,
        onBack: onBack,
      ),
      actions: actions,
    ),
    body: AppContentColumn(
      // top: false because the AppBar already clears the status bar.
      child: SafeArea(top: false, bottom: false, child: _body(context)),
    ),
  );
}
