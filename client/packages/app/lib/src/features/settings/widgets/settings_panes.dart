// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings as a nav beside a pane, rather than every section stacked in one
/// scroll behind full-width hairlines.
///
/// The old shape put nine sections in a single column, each separated by a
/// divider running the whole width. That reads as one undifferentiated list:
/// nothing tells you how much there is, the dividers compete with the borders
/// of the cards inside each section, and finding "Blocked" means scrolling
/// past six things you were not looking for.
///
/// Here a pane is one idea, its own borders are the only ones in view, and the
/// nav says how many ideas there are.
///
/// **Compact drills rather than navigating.** On a phone the nav *is* the
/// screen and choosing a pane pushes it in, so there is one structure at two
/// widths instead of a separate mobile design to keep in step. The pushed pane
/// is the same widget the wide layout puts on the right.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../routing/close_screen.dart';
import 'settings_hairline.dart';
import 'settings_rail_fade.dart';
import 'settings_section_header.dart';
import 'settings_search.dart';
import '../providers/settings_index.dart';

import 'settings_pane.dart';
import 'settings_pane_body.dart';
import 'settings_panes_chrome.dart';
import 'settings_sub_pages.dart';

export 'settings_pane.dart';
export 'settings_sub_pages.dart';

class SettingsPanesScaffold extends StatefulWidget {
  const SettingsPanesScaffold({
    super.key,
    required this.title,
    required this.groups,
    required this.backTooltip,
    required this.backFallback,
    this.footer,
    this.initialPaneId,
    this.initialPageId,
    this.onPaneChanged,
    this.onPageChanged,
    this.searchEntries = const [],
  });

  final String title;

  /// What the search field above the nav can find; empty hides the field.
  final List<SettingsEntry> searchEntries;

  /// The pane shown first; on a phone this opens straight into it.
  ///
  /// Also the route's own answer: when it changes after the first build the
  /// selection follows, which is how a pane in the URL reaches this widget.
  final String? initialPaneId;

  /// A key of the pane's [SettingsPane.subPages], opened on top of it.
  final String? initialPageId;

  /// Told the pane the user picked, or null for the nav on a phone, so the
  /// route can carry it in its location and a reload lands on the same pane.
  final ValueChanged<String?>? onPaneChanged;

  /// Told the [SettingsSubPage.urlId] on top of a pane whenever it changes.
  final void Function(String paneId, String? pageId)? onPageChanged;
  final List<SettingsPaneGroup> groups;

  /// Names the destination, not just "Back"; see [BackToButton].
  final String backTooltip;
  final String backFallback;

  /// Sign out: pinned under the wide rail, the last row of the list on compact
  /// so it never costs the list its height.
  final Widget? footer;

  @override
  State<SettingsPanesScaffold> createState() => _SettingsPanesScaffoldState();
}

class _SettingsPanesScaffoldState extends State<SettingsPanesScaffold> {
  late String? _selectedId = widget.initialPaneId;
  final _highlight = ValueNotifier<String?>(null);
  final _stacks = <String, SettingsSubPageStack>{};
  final _pageKeys = Expando<GlobalKey>();

  /// The page last told to the route, so its own answer is not replayed.
  String? _toldPage;
  bool _quiet = false;

  @override
  void initState() {
    super.initState();
    _openPages(widget.initialPaneId, widget.initialPageId);
  }

  @override
  void dispose() {
    _highlight.dispose();
    for (final stack in _stacks.values) {
      stack.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(SettingsPanesScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialPaneId != oldWidget.initialPaneId) {
      _selectedId = widget.initialPaneId;
    }
    if (widget.initialPageId != _toldPage) {
      _openPages(widget.initialPaneId, widget.initialPageId);
    }
  }

  // One per pane, so its content keeps its state when the window crosses the width that swaps the two-pane layout for the drill-in.
  final _contentKeys = <String, GlobalKey>{};

  GlobalKey _contentKey(SettingsPane pane) =>
      _contentKeys.putIfAbsent(pane.id, GlobalKey.new);

  GlobalKey _pageKey(SettingsSubPage page) => _pageKeys[page] ??= GlobalKey();

  SettingsSubPageStack _stackFor(String paneId) => _stacks.putIfAbsent(
    paneId,
    () => SettingsSubPageStack()..addListener(() => _onStack(paneId)),
  );

  void _onStack(String paneId) {
    if (!mounted || _quiet) return;
    setState(() {});
    final page = _stacks[paneId]!.urlId;
    if (page == _toldPage) return;
    _toldPage = page;
    widget.onPageChanged?.call(paneId, page);
  }

  /// Opens the pages a link names, without telling the route what it said.
  void _openPages(String? paneId, String? pageId) {
    final pane = _allPanes.where((p) => p.id == paneId).firstOrNull;
    _toldPage = pageId;
    if (pane == null) return;
    final pages = pageId == null ? null : pane.subPages[pageId];
    _quietly(() {
      for (final entry in _stacks.entries) {
        if (entry.key != pane.id) entry.value.clear();
      }
      _stackFor(pane.id).replace(pages?.call() ?? const []);
    });
  }

  void _quietly(VoidCallback change) {
    _quiet = true;
    try {
      change();
    } finally {
      _quiet = false;
    }
  }

  SettingsSubPageStack? get _openStack =>
      _stacks.values.where((s) => !s.isEmpty).firstOrNull;

  /// Runs [then] once the open page lets go; every stack is cleared first.
  Future<void> _leave(VoidCallback then) async {
    final stack = _openStack;
    if (stack != null && !await stack.canLeave()) return;
    if (!mounted) return;
    _quietly(() {
      for (final s in _stacks.values) {
        s.clear();
      }
    });
    _toldPage = null;
    then();
  }

  void _close() =>
      unawaited(_leave(() => closeScreen(context, widget.backFallback)));

  void _select(String? id) {
    setState(() => _selectedId = id);
    widget.onPaneChanged?.call(id);
  }

  List<SettingsPane> get _allPanes => [
    for (final group in widget.groups) ...group.panes,
  ];

  SettingsPane? get _selected {
    final panes = _allPanes;
    if (panes.isEmpty) return null;
    return panes.where((p) => p.id == _selectedId).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kSettingsTwoPaneWidth;
    final panes = _allPanes;
    // Wide always shows something: an empty pane beside a nav is a hole.
    final selected = wide ? (_selected ?? panes.firstOrNull) : _selected;
    final stack = selected == null ? null : _stackFor(selected.id);
    final blocking = stack?.blocking ?? false;
    return PopScope(
      canPop: (wide || (stack?.isEmpty ?? true)) && !blocking,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || stack == null) return;
        if (!wide && !stack.isEmpty) {
          unawaited(stack.pop());
          return;
        }
        _close();
      },
      child: SettingsHighlight(
        notifier: _highlight,
        child: _layout(context, wide, selected, stack),
      ),
    );
  }

  Widget _compactPane(SettingsPane pane, SettingsSubPageStack stack) {
    final page = stack.top;
    final body = SafeArea(
      top: false,
      bottom: false,
      child: SettingsPaneBody(
        pane: pane,
        contentKey: _contentKey(pane),
        stack: stack,
        pageKey: _pageKey,
      ),
    );
    if (page != null && page.ownsHeader) return Scaffold(body: body);
    return Scaffold(
      appBar: AppBar(
        title: Text(page?.title ?? pane.label),
        leading: IconButton(
          icon: const Icon(AppIcons.back),
          tooltip: page?.backLabel ?? 'Back to ${widget.title.toLowerCase()}',
          onPressed: page != null
              ? () => unawaited(stack.pop())
              : () => _select(null),
        ),
        actions: page == null ? pane.actions : null,
      ),
      body: body,
    );
  }

  Widget _layout(
    BuildContext context,
    bool wide,
    SettingsPane? selected,
    SettingsSubPageStack? stack,
  ) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final panes = _allPanes;

    if (!wide && selected != null) return _compactPane(selected, stack!);

    void onSelect(String id) => unawaited(
      _leave(() {
        final pane = panes.where((p) => p.id == id).firstOrNull;
        final route = pane?.compactRoute;
        if (!wide && route != null) {
          context.push(route);
          return;
        }
        _select(id);
      }),
    );

    final nav = _Nav(
      groups: widget.groups,
      rail: wide,
      selectedId: selected?.id,
      // Wide only: on compact no lit row is ever visible beside its pane.
      showSelection: wide,
      footer: widget.footer,
      searchEntries: settingsEntriesFor(widget.searchEntries, {
        for (final pane in panes) pane.id,
      }),
      onSelect: onSelect,
      onSearchOpen: (entry) {
        _highlight.value = entry.label;
        onSelect(entry.pane);
      },
    );

    if (!wide) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          leading: BackToButton(
            tooltip: widget.backTooltip,
            fallback: widget.backFallback,
          ),
        ),
        body: SafeArea(top: false, bottom: false, child: nav),
      );
    }

    // No app bar beside a nav: the nav carries the title and the way back, the pane its own heading and close.
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 240,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.surfaceSunken,
                  border: Border(right: BorderSide(color: tokens.borderSubtle)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.s12,
                    AppSpacing.s16,
                    AppSpacing.s12,
                    AppSpacing.s16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NavHeader(
                        title: widget.title,
                        backTooltip: widget.backTooltip,
                        backFallback: widget.backFallback,
                        onBack: _close,
                        showBack: stack?.isEmpty ?? true,
                      ),
                      Expanded(child: nav),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: selected == null
                  ? const SizedBox.shrink()
                  : SettingsPaneBody(
                      pane: selected,
                      contentKey: _contentKey(selected),
                      stack: stack!,
                      pageKey: _pageKey,
                      showHeading: true,
                      onClose: _close,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.groups,
    required this.rail,
    required this.selectedId,
    required this.showSelection,
    required this.onSelect,
    required this.searchEntries,
    required this.onSearchOpen,
    this.footer,
  });

  final List<SettingsPaneGroup> groups;
  final List<SettingsEntry> searchEntries;
  final ValueChanged<SettingsEntry> onSearchOpen;

  /// Inside the wide layout's nav column, which already pads and titles it.
  final bool rail;
  final String? selectedId;
  final bool showSelection;
  final void Function(String) onSelect;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final list = _list(context);
    return Column(
      children: [
        Expanded(
          child: searchEntries.isEmpty
              ? list
              : SettingsSearchArea(
                  entries: searchEntries,
                  paneLabels: {
                    for (final group in groups)
                      for (final pane in group.panes) pane.id: pane.label,
                  },
                  onOpen: onSearchOpen,
                  padding: rail
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
                  child: list,
                ),
        ),
        // A rule, so a row the list cuts off reads as scrolled under it rather than overlapped.
        if (footer != null && rail) ...[const SettingsHairline(), footer!],
      ],
    );
  }

  Widget _list(BuildContext context) =>
      rail ? _railList(context) : _compactList(context);

  Widget _railList(BuildContext context) {
    return SettingsRailFade(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          for (final (index, group) in groups.indexed) ...[
            if (group.label case final label?)
              GroupLabel(label, first: index == 0)
            else
              const SizedBox(height: AppSpacing.s20),
            for (final pane in group.panes) _row(context, pane),
          ],
        ],
      ),
    );
  }

  // Each group a raised card on the page, the same two tones the wide nav and its panes show.
  Widget _compactList(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        for (final (index, group) in groups.indexed)
          SettingsSectionCard(
            title: group.label,
            topGap: index == 0 ? AppSpacing.s8 : kSettingsSectionTopGap,
            children: [for (final pane in group.panes) _row(context, pane)],
          ),
        if (footer != null)
          SettingsSectionCard(
            topGap: kSettingsSectionTopGap,
            children: [footer!],
          ),
      ],
    );
  }

  Widget _row(BuildContext context, SettingsPane pane) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      label: pane.label,
      height: rail ? 32 : null,
      // Sized and colored to match the trailing chevron below, not Flutter's ~24px default.
      leading: pane.icon == null
          ? null
          : Icon(pane.icon, size: AppSizes.icon16, color: tokens.textSecondary),
      meta: pane.badge,
      selected: showSelection && pane.id == selectedId,
      // A chevron only where the row actually goes somewhere.
      trailing: showSelection
          ? null
          : Icon(
              AppIcons.chevronRight,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
      onTap: () => onSelect(pane.id),
    );
  }
}
