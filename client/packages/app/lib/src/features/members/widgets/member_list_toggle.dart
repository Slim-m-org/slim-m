// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one control that opens and closes the docked member list, shared by
/// every header that sits above a pane the list can dock beside.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import 'member_pane.dart';

class MemberListToggle extends ConsumerWidget {
  const MemberListToggle({super.key});

  /// Whether the list can dock at all here; a toggle shown past that would sit lit over a pane that never appears.
  static bool fits(BuildContext context) =>
      LayoutClass.of(context).fitsMemberPane(MediaQuery.sizeOf(context).width);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = memberPaneWanted(ref, MediaQuery.sizeOf(context));
    return AppIconButton(
      icon: AppIcons.members,
      semanticLabel: 'Toggle member list',
      active: visible,
      onPressed: () {
        ref.read(memberPaneVisibleProvider.notifier).state = !visible;
        ref.read(memberPaneOpenedByHandProvider.notifier).state = !visible;
      },
    );
  }
}
