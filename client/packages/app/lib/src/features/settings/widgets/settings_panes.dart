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

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../routing/close_screen.dart';
import 'settings_section_header.dart';

part 'settings_panes_chrome.dart';

/// How wide a [SettingsPane.wide] pane may get, matching the room a Space
/// settings panel leaves beside the nav (decision 0061).
const double kSettingsWideContentMax = 880;

/// One entry in the nav, and the pane it opens.
class SettingsPane {
  const SettingsPane({
    required this.id,
    required this.label,
    required this.builder,
    this.icon,
    this.badge,
    this.scrollable = true,
    this.padding = const EdgeInsets.all(AppSpacing.s16),
    this.compactRoute,
    this.actions,
    this.wide = false,
    this.headingBuilder,
  });

  /// Stable across rebuilds, so the selection survives a pane's own setState.
  final String id;
  final String label;

  /// Built lazily: a pane that fetches does not fetch until it is looked at,
  /// which is the other half of why this is not one long scroll.
  final WidgetBuilder builder;

  /// Drawn plain, matching every other settings row in this app
  /// ([SpaceSettingsSection], `DevicesSection`, `BlockedSection`): the nav
  /// list is what read as text-and-a-chevron with nothing else beside it.
  final IconData? icon;

  /// A count shown at the trailing edge, for a pane whose interest is how
  /// many things are in it.
  final String? badge;

  /// Mirrors [SettingsScreenScaffold]'s own pair: a pane that scrolls itself
  /// (a paged list) sets false, and the padding is the pane's to override.
  final bool scrollable;
  final EdgeInsets padding;

  /// A route to push instead of drilling in place on compact layouts.
  ///
  /// Space settings sets this so a phone keeps the real, deep-linkable admin
  /// screens (and their routes stay reachable); wide layouts always embed
  /// [builder]'s pane beside the nav regardless.
  final String? compactRoute;

  /// App-bar actions shown while this pane is the one on screen, standing in
  /// for the standalone screen's own (roles' "New role", say).
  final List<Widget>? actions;

  /// A grid or list that wants the wider cap; forms and prose keep the
  /// narrower [kContentColumnMax] so their lines stay readable.
  final bool wide;

  /// Replaces the heading row beside the nav, for a pane that swaps to an inner page and names it itself (a breadcrumb).
  final Widget Function(BuildContext context, VoidCallback? onClose)?
  headingBuilder;
}

/// A run of panes, usually under a heading: `You`, `Safety`.
class SettingsPaneGroup {
  const SettingsPaneGroup({required this.panes, this.label});

  /// Every group carries one. `About slim-m` used to sit under a bare gap on
  /// the theory that naming a group of one is decoration; the owner read the
  /// gap as a section "clearly sectioned off but missing its header", which
  /// is the better reading - the divider already says "new group", and a
  /// group with no name is a question, not a saving. Nullable only so a
  /// caller can still build one without, never the shape the nav ships.
  final String? label;
  final List<SettingsPane> panes;
}

class SettingsPanesScaffold extends StatefulWidget {
  const SettingsPanesScaffold({
    super.key,
    required this.title,
    required this.groups,
    required this.backTooltip,
    required this.backFallback,
    this.footer,
    this.initialPaneId,
    this.onPaneChanged,
  });

  final String title;

  /// The pane shown first; on a phone this opens straight into it.
  ///
  /// Also the route's own answer: when it changes after the first build the
  /// selection follows, which is how a pane in the URL reaches this widget.
  final String? initialPaneId;

  /// Told the pane the user picked, or null for the nav on a phone, so the
  /// route can carry it in its location and a reload lands on the same pane.
  final ValueChanged<String?>? onPaneChanged;
  final List<SettingsPaneGroup> groups;

  /// Names the destination, not just "Back"; see [BackToButton].
  final String backTooltip;
  final String backFallback;

  /// Below the nav, pinned: sign out. Who-you-are lives inside the "Account &
  /// presence" pane itself now, not above the nav as a second, editable copy
  /// of the same identity - see that pane's own doc comment.
  final Widget? footer;

  @override
  State<SettingsPanesScaffold> createState() => _SettingsPanesScaffoldState();
}

class _SettingsPanesScaffoldState extends State<SettingsPanesScaffold> {
  late String? _selectedId = widget.initialPaneId;

  @override
  void didUpdateWidget(SettingsPanesScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialPaneId != oldWidget.initialPaneId) {
      _selectedId = widget.initialPaneId;
    }
  }

  // One per pane, so its content keeps its state when the window crosses the width that swaps the two-pane layout for the drill-in.
  final _contentKeys = <String, GlobalKey>{};

  GlobalKey _contentKey(SettingsPane pane) =>
      _contentKeys.putIfAbsent(pane.id, GlobalKey.new);

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
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final wide = MediaQuery.sizeOf(context).width >= kSettingsTwoPaneWidth;
    final panes = _allPanes;

    // Wide always shows something: an empty pane beside a nav is a hole.
    final selected = wide ? (_selected ?? panes.firstOrNull) : _selected;

    if (!wide && selected != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(selected.label),
          leading: IconButton(
            icon: const Icon(AppIcons.back),
            tooltip: 'Back to ${widget.title.toLowerCase()}',
            onPressed: () => _select(null),
          ),
          actions: selected.actions,
        ),
        body: SafeArea(
          top: false,
          child: _PaneBody(pane: selected, contentKey: _contentKey(selected)),
        ),
      );
    }

    final nav = _Nav(
      groups: widget.groups,
      rail: wide,
      selectedId: selected?.id,
      // Wide only: on compact no lit row is ever visible beside its pane.
      showSelection: wide,
      footer: widget.footer,
      onSelect: (id) {
        final pane = panes.where((p) => p.id == id).firstOrNull;
        final route = pane?.compactRoute;
        if (!wide && route != null) {
          context.push(route);
          return;
        }
        _select(id);
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
        body: SafeArea(top: false, child: nav),
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
                      _NavHeader(
                        title: widget.title,
                        backTooltip: widget.backTooltip,
                        backFallback: widget.backFallback,
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
                  : _PaneBody(
                      pane: selected,
                      contentKey: _contentKey(selected),
                      showHeading: true,
                      onClose: () => closeScreen(context, widget.backFallback),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A pane's own content, keyed by its id so switching panes does not carry the
/// previous one's scroll offset or form state across - and faded in on that
/// same key, so choosing a pane hands the eye the new content rather than
/// teleporting it.
///
/// Capped at [AppContentColumn]'s own width and centred, or a pane's rows
/// stretch across whatever the window happens to be - the owner's own "very
/// flat" report on a wide desktop window, where the nav's 240px left nothing
/// else bounding it.
class _PaneBody extends StatelessWidget {
  const _PaneBody({
    required this.pane,
    required this.contentKey,
    this.showHeading = false,
    this.onClose,
  });

  /// Beside a nav: the pane's own close, at the right of its heading.
  final VoidCallback? onClose;

  /// The redesign's pane inset beside a nav, for a pane that kept the default.
  static const _wideInset = EdgeInsets.fromLTRB(32, 24, 32, 40);

  EdgeInsets get _padding =>
      showHeading && pane.padding == const EdgeInsets.all(AppSpacing.s16)
      ? _wideInset
      : pane.padding;

  Widget _heading(BuildContext context) =>
      pane.headingBuilder?.call(context, onClose) ??
      SettingsPaneHeading(pane.label, actions: pane.actions, onClose: onClose);

  final SettingsPane pane;

  /// Owned by the scaffold, so the pane's own state outlives this widget.
  final GlobalKey contentKey;

  /// Wide only: beside the nav nothing else names the pane, where on compact
  /// the app bar already does.
  final bool showHeading;

  @override
  Widget build(BuildContext context) => AppFadeIn(
    key: ValueKey(pane.id),
    duration: AppMotion.fast,
    offset: 0,
    child: AppContentColumn(
      maxWidth: pane.wide ? kSettingsWideContentMax : kContentColumnMax,
      child: pane.scrollable
          ? ListView(
              padding: _padding,
              children: [
                if (showHeading) _heading(context),
                KeyedSubtree(
                  key: contentKey,
                  child: Builder(builder: pane.builder),
                ),
              ],
            )
          : showHeading
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    _padding.left,
                    _padding.top,
                    _padding.right,
                    0,
                  ),
                  child: _heading(context),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      _padding.left,
                      0,
                      _padding.right,
                      _padding.bottom,
                    ),
                    child: KeyedSubtree(
                      key: contentKey,
                      child: Builder(builder: pane.builder),
                    ),
                  ),
                ),
              ],
            )
          : Padding(
              padding: pane.padding,
              child: KeyedSubtree(
                key: contentKey,
                child: Builder(builder: pane.builder),
              ),
            ),
    ),
  );
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.groups,
    required this.rail,
    required this.selectedId,
    required this.showSelection,
    required this.onSelect,
    this.footer,
  });

  final List<SettingsPaneGroup> groups;

  /// Inside the wide layout's nav column, which already pads and titles it.
  final bool rail;
  final String? selectedId;
  final bool showSelection;
  final void Function(String) onSelect;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: rail
              ? ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final (index, group) in groups.indexed) ...[
                      if (group.label case final label?)
                        _GroupLabel(label, first: index == 0)
                      else
                        const SizedBox(height: AppSpacing.s20),
                      for (final pane in group.panes) _row(context, pane),
                    ],
                  ],
                )
              // Compact: each group a raised card on the page, the same two tones the wide nav and its panes show.
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.s16,
                    0,
                    AppSpacing.s16,
                    AppSpacing.s16,
                  ),
                  children: [
                    for (final group in groups)
                      SettingsSectionCard(
                        title: group.label,
                        children: [
                          for (final pane in group.panes) _row(context, pane),
                        ],
                      ),
                  ],
                ),
        ),
        if (footer != null)
          Padding(
            padding: rail
                ? EdgeInsets.zero
                : const EdgeInsets.all(AppSpacing.s8),
            child: footer!,
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
