// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A host-run connector's section of its Dock page (decision 0134): whether
/// this server can run it, its state, start and stop, what it was approved to
/// run, and its recent output. The Dock is admin-only, so this is too.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/app_lifecycle.dart';
import '../../providers/dock_host_run_providers.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_section_header.dart';
import 'dock_host_run_ask.dart';

const _refreshEvery = Duration(seconds: 5);
const _logBoxHeight = 240.0;
const _rowInset = EdgeInsets.symmetric(
  horizontal: AppSpacing.s16,
  vertical: 10,
);

Widget _inset(Widget child) => Padding(padding: _rowInset, child: child);

String dockHostRunStateLabel(api.HostRunState state) => switch (state) {
  api.HostRunState.running => 'Running',
  api.HostRunState.stopped => 'Stopped',
  api.HostRunState.crashed => 'Crashed, restarting',
  api.HostRunState.disabledAfterCrashes => 'Turned off after crashing',
  api.HostRunState.refused => 'Refused by this server',
  api.HostRunState.starting => 'Starting',
  api.HostRunState.runtimeUnavailable => 'Runtime unavailable',
  api.HostRunState.unknown => 'Unknown',
};

class DockHostRunPanel extends ConsumerStatefulWidget {
  const DockHostRunPanel({
    super.key,
    required this.moduleId,
    required this.ask,
    required this.installed,
    required this.busy,
    required this.onSetEnabled,
  });

  final String moduleId;
  final api.HostRunAsk ask;
  final api.InstalledDockModule? installed;
  final bool busy;
  final ValueChanged<bool> onSetEnabled;

  @override
  ConsumerState<DockHostRunPanel> createState() => _DockHostRunPanelState();
}

class _DockHostRunPanelState extends ConsumerState<DockHostRunPanel> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(_refreshEvery, (_) {
      if (widget.installed == null || !mounted || !isSeenNow(context)) return;
      ref.invalidate(connectorHostRunProvider(widget.moduleId));
      ref.invalidate(connectorHostRunLogsProvider(widget.moduleId));
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final installed = widget.installed;
    return SettingsSectionCard(
      title: 'Run by this server',
      children: installed == null
          ? [_availability(), _inset(DockHostRunAsk(ask: widget.ask))]
          : _installed(installed),
    );
  }

  Widget _availability() {
    final runtime = ref.watch(connectorRuntimeProvider).value;
    final text = switch (runtime) {
      null => 'Runs in a sandbox on this server.',
      api.ConnectorRuntimeStatus(configured: false) =>
        'This server is not set up to run connectors. An operator has to '
            'turn on the connector runtime first.',
      api.ConnectorRuntimeStatus(available: false) =>
        'The connector runtime is unavailable right now.',
      _ => 'Runs in a sandbox on this server.',
    };
    return SettingsInfoLine(text);
  }

  List<Widget> _installed(api.InstalledDockModule installed) {
    final status = ref.watch(connectorHostRunProvider(widget.moduleId));
    final run = status.value;
    final state = run?.state ?? api.HostRunState.unknown;
    final down = state == api.HostRunState.runtimeUnavailable;
    return [
      SettingsDetailRow(
        title: 'Status',
        detail: status.hasError && run == null
            ? 'Could not be read'
            : dockHostRunStateLabel(state),
        stackTrailingWhenNarrow: true,
        trailing: AppButton(
          label: installed.enabled ? 'Stop' : 'Start',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          disabled: widget.busy || (down && !installed.enabled),
          onPressed: () => widget.onSetEnabled(!installed.enabled),
        ),
      ),
      if (run?.lastError case final reason?)
        Padding(
          padding: _rowInset,
          child: AppCallout(
            tone: AppCalloutTone.warn,
            child: Text(reason, style: AppText.caption),
          ),
        ),
      if (run != null && run.restarts > 0)
        SettingsDetailRow(
          title: 'Restarts',
          detail: run.restarts == 1
              ? '1 in the last 10 minutes'
              : '${run.restarts} in the last 10 minutes',
        ),
      _inset(DockHostRunAsk(ask: run?.ask ?? widget.ask)),
      _inset(_DockHostRunLogs(moduleId: widget.moduleId)),
    ];
  }
}

class _DockHostRunLogs extends ConsumerWidget {
  const _DockHostRunLogs({required this.moduleId});

  final String moduleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final logs = ref.watch(connectorHostRunLogsProvider(moduleId));
    final lines = logs.value;
    final caption = AppText.caption.copyWith(color: tokens.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Recent output', style: caption),
        const SizedBox(height: AppSpacing.s4),
        if (lines == null)
          Text(
            logs.hasError ? 'Output is unavailable right now.' : 'Loading',
            style: caption,
          )
        else if (lines.isEmpty)
          Text('No output yet.', style: caption)
        else
          Container(
            constraints: const BoxConstraints(maxHeight: _logBoxHeight),
            padding: const EdgeInsets.all(AppSpacing.s8),
            decoration: BoxDecoration(
              color: tokens.surfaceSunken,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: tokens.borderSubtle),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                [for (final l in lines) l.text].join('\n'),
                style: AppText.code.copyWith(color: tokens.textPrimary),
              ),
            ),
          ),
      ],
    );
  }
}
