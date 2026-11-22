// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One Dock panel (decision 0132): a header with the panel's name and a close
/// button over the module's scene, painted by the same [ModuleCommandOutput]
/// every other module surface uses. The scene lives in
/// [modulePanelRunsProvider], so this pane can unmount and come back to it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/app_lifecycle.dart';
import '../providers/module_panels.dart';
import 'module_command_output.dart';

class ModulePanelView extends ConsumerStatefulWidget {
  const ModulePanelView({
    super.key,
    required this.panel,
    required this.onClose,
  });

  final api.ModulePanel panel;
  final VoidCallback onClose;

  @override
  ConsumerState<ModulePanelView> createState() => _ModulePanelViewState();
}

class _ModulePanelViewState extends ConsumerState<ModulePanelView> {
  Timer? _ticker;
  Duration? _tickEvery;

  ModulePanelRuns get _runs => ref.read(modulePanelRunsProvider.notifier);

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// One ticker per interval; each tick redraws only while the pane is seen.
  void _keepTicking(Duration? every) {
    if (every == _tickEvery) return;
    _ticker?.cancel();
    _tickEvery = every;
    _ticker = every == null
        ? null
        : Timer.periodic(every, (_) {
            if (!mounted || !TickerMode.valuesOf(context).enabled) return;
            final visible = windowScopeOf(context)?.read(appVisibleProvider);
            if (visible == false) return;
            unawaited(_runs.refresh(widget.panel));
          });
  }

  @override
  Widget build(BuildContext context) {
    final panel = widget.panel;
    final run = ref.watch(
      modulePanelRunsProvider.select((runs) => runs[panel.key]),
    );
    if (run == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_runs.open(panel));
      });
    }
    _keepTicking(run?.refreshEvery);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PanelHeader(name: panel.name, onClose: widget.onClose),
        Expanded(child: _body(run)),
      ],
    );
  }

  Widget _body(ModulePanelRun? run) {
    final panel = widget.panel;
    if (run?.result case final result?) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.s12),
        child: ModuleCommandOutput(
          result: result,
          moduleId: panel.moduleId,
          command: panel.command,
          runAction: (input) => _runs.act(panel, input),
        ),
      );
    }
    if (run?.error case final error?) {
      return AppErrorState(
        message: error,
        onRetry: () => unawaited(_runs.open(panel, retry: true)),
      );
    }
    return const Center(child: AppSpinner(size: AppSpinnerSize.md));
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.name, required this.onClose});

  final String name;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // The header bar's height, so the panel's top edge lines up with the channel header beside it.
    return Container(
      height: AppSizes.headerBar,
      padding: const EdgeInsets.only(
        left: AppSpacing.s12,
        right: AppSpacing.s4,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Row(
        children: [
          Icon(
            AppIcons.dock,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
          const SizedBox(width: AppSpacing.s8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  fontWeight: AppWeights.semi,
                  color: tokens.textPrimary,
                ),
              ),
            ),
          ),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Close $name',
            tooltip: 'Close panel',
            iconSize: AppSizes.icon16,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
