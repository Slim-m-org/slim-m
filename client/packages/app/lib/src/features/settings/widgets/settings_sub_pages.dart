// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A page pushed inside a settings pane, so a pane goes one level deeper
/// without leaving its nav and close (rule 5 of
/// `docs/design/desktop-vs-mobile.md`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';

/// One level inside a pane: the Themes gallery under Appearance, say.
class SettingsSubPage {
  const SettingsSubPage({
    required this.id,
    required this.title,
    required this.backLabel,
    required this.builder,
    this.urlId,
    this.ownsHeader = false,
  });

  final String id;
  final String title;

  /// The back button's tooltip and semantics label: 'Back to Appearance'.
  final String backLabel;
  final WidgetBuilder builder;

  /// Written to `?page=`; null for a page no link opens.
  final String? urlId;

  /// The page draws its own [SettingsSubPageHeader] and gets no insets.
  final bool ownsHeader;
}

/// Asked before the page it was set for is left.
abstract interface class SettingsLeaveGuard {
  /// True while leaving would lose something, so a back gesture must ask.
  bool get blocking;

  /// Asks the person; true lets them leave.
  Future<bool> confirmLeave();
}

/// The pages pushed inside one pane, top last.
class SettingsSubPageStack extends ChangeNotifier {
  final _pages = <SettingsSubPage>[];
  final _guards = <int, SettingsLeaveGuard>{};
  SettingsLeaveGuard? _paneGuard;
  bool _blocking = false;
  bool _disposed = false;

  List<SettingsSubPage> get pages => List.unmodifiable(_pages);
  bool get isEmpty => _pages.isEmpty;
  SettingsSubPage? get top => _pages.lastOrNull;

  /// The guard of the page on top, if it set one.
  SettingsLeaveGuard? get guard =>
      _pages.isEmpty ? null : _guards[_pages.length - 1];

  bool get blocking =>
      (_paneGuard?.blocking ?? false) || _guards.values.any((g) => g.blocking);

  /// What `?page=` carries: the nearest page from the top that has a link.
  String? get urlId => _pages.reversed.map((p) => p.urlId).nonNulls.firstOrNull;

  void push(SettingsSubPage page) {
    _pages.add(page);
    notifyListeners();
  }

  /// Leaves the top page once its guard allows it; false when it did not.
  Future<bool> pop() async {
    final top = guard;
    if (_pages.isEmpty) return false;
    if (top != null && top.blocking && !await top.confirmLeave()) return false;
    _release(_pages.length - 1);
    _pages.removeLast();
    _changed();
    return true;
  }

  /// Sets [guard] for the page on top; null clears it.
  void setGuard(SettingsLeaveGuard? guard) {
    if (_pages.isEmpty) return;
    final index = _pages.length - 1;
    _release(index);
    if (guard != null) {
      _guards[index] = guard;
      if (guard is Listenable) (guard as Listenable).addListener(_onGuard);
    }
    _onGuard();
  }

  /// Sets [guard] for the pane itself, under every page; no page change releases it.
  void setPaneGuard(SettingsLeaveGuard guard) {
    _releasePane();
    _paneGuard = guard;
    if (guard is Listenable) (guard as Listenable).addListener(_onGuard);
    _onGuard();
  }

  /// Clears the pane guard only while it is still [guard], so a successor's stays.
  void releasePaneGuard(SettingsLeaveGuard guard) {
    if (!identical(_paneGuard, guard)) return;
    _releasePane();
    _onGuard();
  }

  /// Asks every blocking guard, top page first and the pane last; true when nothing stands in the way.
  Future<bool> canLeave() async {
    for (final index in _guards.keys.toList()..sort((a, b) => b - a)) {
      final guard = _guards[index];
      if (guard != null && guard.blocking && !await guard.confirmLeave()) {
        return false;
      }
    }
    final pane = _paneGuard;
    return pane == null || !pane.blocking || await pane.confirmLeave();
  }

  /// Replaces every page without asking, for a caller that already did.
  void replace(List<SettingsSubPage> pages) {
    for (final index in _guards.keys.toList()) {
      _release(index);
    }
    _pages
      ..clear()
      ..addAll(pages);
    _changed();
  }

  void clear() => replace(const []);

  void _release(int index) {
    final old = _guards.remove(index);
    if (old is Listenable) (old as Listenable).removeListener(_onGuard);
  }

  void _releasePane() {
    final old = _paneGuard;
    _paneGuard = null;
    if (old is Listenable) (old as Listenable).removeListener(_onGuard);
  }

  void _onGuard() {
    if (_disposed || blocking == _blocking) return;
    // A guard set while its page builds is reported once that build is done.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _onGuard());
      return;
    }
    _changed();
  }

  void _changed() {
    _blocking = blocking;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final index in _guards.keys.toList()) {
      _release(index);
    }
    _releasePane();
    super.dispose();
  }
}

/// Hands a pane's stack to the pages and rows inside it.
class SettingsSubPages extends InheritedNotifier<SettingsSubPageStack> {
  const SettingsSubPages({
    super.key,
    required SettingsSubPageStack stack,
    this.bottomInset = 0,
    this.onClose,
    required super.child,
  }) : super(notifier: stack);

  /// What a page pads the end of its own scroll with.
  final double bottomInset;

  /// Closes settings once the open page lets go; null below the two-pane width.
  final VoidCallback? onClose;

  /// Read without depending: callers push and pop, they do not rebuild on it.
  static SettingsSubPageStack of(BuildContext context) => maybeOf(context)!;

  static SettingsSubPageStack? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SettingsSubPages>()?.notifier;

  /// The bottom padding a page's scroll view ends with.
  static double bottomInsetOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SettingsSubPages>()
          ?.bottomInset ??
      MediaQuery.paddingOf(context).bottom;

  /// The guarded close an [SettingsSubPage.ownsHeader] page puts in its header.
  static VoidCallback? closeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SettingsSubPages>()?.onClose;

  @override
  bool updateShouldNotify(SettingsSubPages oldWidget) =>
      super.updateShouldNotify(oldWidget) ||
      oldWidget.bottomInset != bottomInset;
}

/// A sub-page's heading: beside the nav a 40-high row where the pane's own
/// heading sits, and below [kSettingsTwoPaneWidth] a primary app bar.
class SettingsSubPageHeader extends StatelessWidget {
  const SettingsSubPageHeader({
    super.key,
    required this.title,
    required this.backLabel,
    required this.onBack,
    this.actions,
    this.onClose,
  });

  final String title;
  final String backLabel;
  final VoidCallback onBack;
  final List<Widget>? actions;

  /// Beside the nav: closes settings, at the right end of the row.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kSettingsTwoPaneWidth;
    final back = AppIconButton(
      key: const Key('settings-sub-page-back'),
      icon: AppIcons.back,
      semanticLabel: backLabel,
      tooltip: backLabel,
      onPressed: onBack,
    );
    if (!wide) {
      return AppBar(
        primary: true,
        leading: AppTouchTargets.of(context)
            ? Center(child: back)
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
                child: back,
              ),
        titleSpacing: 0,
        title: Text(title),
        actions: actions,
      );
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s8),
            child: back,
          ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: AppText.heading.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
          ),
          ...?actions,
          if (onClose != null)
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Close settings',
              tooltip: 'Close settings',
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
