// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one control that opens and closes the docked member list, shared by
/// every header that sits above a pane the list can dock beside.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../widgets/header_icon_action.dart';
import 'member_pane.dart';

class MemberListToggle extends ConsumerWidget {
  const MemberListToggle({super.key, this.yielded = false, this.onReveal});

  /// The list is held back by another pane in its slot, so the toggle reads off and a press brings the list back.
  final bool yielded;

  /// Closes the pane the list yielded to; called when the list is asked for while [yielded].
  final VoidCallback? onReveal;

  /// Whether the list can dock at all here; a toggle shown past that would sit lit over a pane that never appears.
  static bool fits(BuildContext context) =>
      LayoutClass.of(context).fitsMemberPane(MediaQuery.sizeOf(context).width);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible =
        !yielded && memberPaneWanted(ref, MediaQuery.sizeOf(context));
    return HeaderIconAction(
      icon: AppIcons.members,
      label: 'Toggle member list',
      active: visible,
      onPressed: () {
        if (yielded) {
          onReveal?.call();
          ref.read(memberPaneVisibleProvider.notifier).state = true;
          ref.read(memberPaneOpenedByHandProvider.notifier).state = true;
          return;
        }
        ref.read(memberPaneVisibleProvider.notifier).state = !visible;
        ref.read(memberPaneOpenedByHandProvider.notifier).state = !visible;
      },
    );
  }
}
