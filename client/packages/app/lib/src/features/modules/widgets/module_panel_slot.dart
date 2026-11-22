// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a Dock panel shows (decision 0131, desktop-vs-mobile.md rule 5):
/// docked in the shell's third-pane slot where `fitsThreadPane` has room, so
/// it stays beside every channel the viewer moves through, and otherwise its
/// own route, full screen on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../routing/routes.dart';
import '../../../widgets/app_panel_reveal.dart';
import '../../channels/providers/threads.dart';
import '../providers/module_panels.dart';
import 'module_panel_view.dart';

/// Opens [panel] from [context]. Docking it takes the slot from a thread
/// docked beside [besideChannelId], so the press always shows the panel.
void openModulePanel(
  BuildContext context,
  WidgetRef ref,
  api.ModulePanel panel, {
  String? besideChannelId,
}) {
  final width = MediaQuery.sizeOf(context).width;
  if (!LayoutClass.fromWidth(width).fitsThreadPane(width)) {
    context.push(Routes.modulePanel(panel.moduleId, panel.command));
    return;
  }
  ref.read(openModulePanelProvider.notifier).state = panel;
  closeDockedThread(ref.read(dockedThreadsProvider.notifier), besideChannelId);
}

/// Whether the open panel takes the third pane this build, given whether that pane [fits].
bool modulePanelDocked(WidgetRef ref, {required bool fits}) =>
    fits && ref.watch(openModulePanelProvider.select((p) => p != null));

/// The docked panel beside the transcript, in the third-pane slot.
class ModulePanelSlot extends ConsumerWidget {
  const ModulePanelSlot({super.key});

  /// The pane's box, for tests that measure where it docks.
  static const paneKey = ValueKey('module-panel-pane');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(openModulePanelProvider);
    if (panel == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      key: paneKey,
      width: kThreadPaneWidth,
      // Container, not DecoratedBox, so the border insets the panel rather than being painted over.
      child: Container(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border(left: BorderSide(color: tokens.borderStrong)),
        ),
        child: AppPanelReveal(
          fromLeft: false,
          child: ModulePanelView(
            key: ValueKey(panel.key),
            panel: panel,
            onClose: () =>
                ref.read(openModulePanelProvider.notifier).state = null,
          ),
        ),
      ),
    );
  }
}
