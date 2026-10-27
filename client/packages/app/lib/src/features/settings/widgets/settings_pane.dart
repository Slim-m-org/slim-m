// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The data a settings nav is built from: a pane and the group it sits in.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

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
