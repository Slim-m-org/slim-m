// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Dock panel as its own page, where no third pane fits beside the chat
/// (decision 0132): full screen on a phone. The panel is looked up by its
/// module and command, so a reload or a deep link opens the same one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/module_panels.dart';
import '../widgets/module_panel_view.dart';

class ModulePanelScreen extends ConsumerWidget {
  const ModulePanelScreen({
    super.key,
    required this.moduleId,
    required this.command,
  });

  final String moduleId;
  final String command;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final panels = ref.watch(modulePanelsProvider);
    return Scaffold(
      backgroundColor: tokens.surfaceBase,
      body: SafeArea(
        child: AppAsyncView<List<api.ModulePanel>>(
          value: AppAsyncState(data: panels.valueOrNull, error: panels.error),
          errorMessage: 'Could not load this panel.',
          onRetry: () => ref.invalidate(modulePanelsProvider),
          data: (context, list) {
            final panel = list
                .where((p) => p.moduleId == moduleId && p.command == command)
                .firstOrNull;
            if (panel == null) {
              return const AppErrorState(
                message: 'This panel is not available.',
              );
            }
            return ModulePanelView(
              panel: panel,
              onClose: () => Navigator.of(context).maybePop(),
            );
          },
        ),
      ),
    );
  }
}
