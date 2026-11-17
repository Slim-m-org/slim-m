// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pane's own content beside the nav or under its app bar, or the sub-page
/// pushed on top of it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_pane.dart';
import 'settings_panes_chrome.dart';
import 'settings_sub_pages.dart';

/// The redesign's pane inset beside a nav, for a pane that kept the default.
const kSettingsWidePaneInset = EdgeInsets.fromLTRB(32, 24, 32, 40);

/// A pane's content, keyed by its id so switching panes does not carry the
/// previous one's scroll offset or form state across, and faded in on that
/// same key; pushed pages stack above it, the lower ones kept alive.
///
/// Capped at [AppContentColumn]'s own width and centred, or a pane's rows
/// stretch across whatever the window happens to be.
class SettingsPaneBody extends StatelessWidget {
  const SettingsPaneBody({
    super.key,
    required this.pane,
    required this.contentKey,
    required this.stack,
    required this.pageKey,
    this.showHeading = false,
    this.onClose,
  });

  final SettingsPane pane;

  /// Owned by the scaffold, so the pane's own state outlives this widget.
  final GlobalKey contentKey;

  final SettingsSubPageStack stack;

  /// One per pushed page, so a page keeps its state across a resize.
  final GlobalKey Function(SettingsSubPage page) pageKey;

  /// Wide only: beside the nav nothing else names the pane, where on compact
  /// the app bar already does.
  final bool showHeading;

  /// Beside a nav: the pane's own close, at the right of its heading.
  final VoidCallback? onClose;

  EdgeInsets _padding(BuildContext context) {
    final base =
        showHeading && pane.padding == const EdgeInsets.all(AppSpacing.s16)
        ? kSettingsWidePaneInset
        : pane.padding;
    return base + EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom);
  }

  Widget _heading(BuildContext context) =>
      pane.headingBuilder?.call(context, onClose) ??
      SettingsPaneHeading(pane.label, actions: pane.actions, onClose: onClose);

  @override
  Widget build(BuildContext context) {
    final pages = stack.pages;
    final padding = _padding(context);
    return SettingsSubPages(
      stack: stack,
      bottomInset: padding.bottom,
      onClose: onClose,
      child: pages.isEmpty
          ? AppFadeIn(
              key: ValueKey(pane.id),
              duration: AppMotion.fast,
              offset: 0,
              child: _column(_body(context, padding)),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                for (final (i, page) in pages.indexed)
                  _KeptPage(
                    shown: i == pages.length - 1,
                    pane: pane.id,
                    page: page,
                    child: page.ownsHeader
                        ? _page(context, page, padding)
                        : _column(_page(context, page, padding)),
                  ),
              ],
            ),
    );
  }

  Widget _column(Widget child) => AppContentColumn(
    maxWidth: pane.wide ? kSettingsWideContentMax : kContentColumnMax,
    child: child,
  );

  Widget _page(BuildContext context, SettingsSubPage page, EdgeInsets inset) {
    final content = KeyedSubtree(
      key: pageKey(page),
      child: Builder(builder: page.builder),
    );
    if (page.ownsHeader) return content;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset.left, inset.top, inset.right, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeading)
            SettingsSubPageHeader(
              title: page.title,
              backLabel: page.backLabel,
              onBack: () => stack.pop(),
              onClose: onClose,
            ),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, EdgeInsets padding) {
    final content = KeyedSubtree(
      key: contentKey,
      child: Builder(builder: pane.builder),
    );
    if (pane.scrollable && !showHeading) {
      return ListView(padding: padding, children: [content]);
    }
    if (!showHeading) return Padding(padding: padding, child: content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            padding.left,
            padding.top,
            padding.right,
            0,
          ),
          child: _heading(context),
        ),
        Expanded(
          child: pane.scrollable
              ? ListView(
                  padding: EdgeInsets.fromLTRB(
                    padding.left,
                    0,
                    padding.right,
                    padding.bottom,
                  ),
                  children: [content],
                )
              : Padding(
                  padding: EdgeInsets.fromLTRB(
                    padding.left,
                    0,
                    padding.right,
                    padding.bottom,
                  ),
                  child: content,
                ),
        ),
      ],
    );
  }
}

/// A page under the one on top stays built but hidden, so going back finds
/// it scrolled and filtered as it was left.
class _KeptPage extends StatelessWidget {
  const _KeptPage({
    required this.shown,
    required this.pane,
    required this.page,
    required this.child,
  });

  final bool shown;
  final String pane;
  final SettingsSubPage page;
  final Widget child;

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: shown,
    child: ExcludeFocus(
      excluding: !shown,
      child: ExcludeSemantics(
        excluding: !shown,
        child: Offstage(
          offstage: !shown,
          child: shown
              ? AppFadeIn(
                  key: ValueKey('$pane/${page.id}'),
                  offset: AppSpacing.s16,
                  child: child,
                )
              : child,
        ),
      ),
    ),
  );
}
