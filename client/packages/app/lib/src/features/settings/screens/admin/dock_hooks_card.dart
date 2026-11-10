// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Checks": where an installed module stands in front of messages and
/// permission checks, its order among the others, whether a failure refuses
/// the action, and how it has been doing. Hidden when it hooks into nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/providers.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

/// How far one press of earlier or later moves a hook.
const dockHookPriorityStep = 10;

const _hookNames = {
  'message.pre_send': 'Before a message is sent',
  'message.pre_edit': 'Before a message is edited',
  'message.send': 'Sending a message',
  'attachment.upload': 'Uploading a file',
  'reaction.add': 'Adding a reaction',
  'voice.join': 'Joining a voice channel',
};

const _phaseNames = {
  'reject': 'can block it',
  'annotate': 'can tag it',
  'rewrite': 'can change it',
};

/// The sentence naming what [hook] does and where.
String dockHookTitle(api.ModuleHook hook) {
  final where = _hookNames[hook.hook] ?? hook.hook;
  if (hook.kind == 'permission') return '$where: can deny it';
  return '$where: ${_phaseNames[hook.phase] ?? hook.phase}';
}

/// How [hook] has been doing, in one line.
String dockHookRecord(api.ModuleHook hook) {
  if (hook.runs == 0) return 'Has not run yet.';
  final runs = hook.runs == 1 ? '1 run' : '${hook.runs} runs';
  final failed = hook.failures == 0 ? 'none failed' : '${hook.failures} failed';
  final last = hook.lastError;
  return last == null
      ? '$runs, $failed.'
      : '$runs, $failed. Last problem: $last';
}

class DockHooksCard extends ConsumerStatefulWidget {
  const DockHooksCard({super.key, required this.moduleId});

  final String moduleId;

  @override
  ConsumerState<DockHooksCard> createState() => _DockHooksCardState();
}

class _DockHooksCardState extends ConsumerState<DockHooksCard>
    with GuardedActionState<DockHooksCard> {
  List<api.ModuleHook>? _hooks;
  String? _loadError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ok = await guard(
      whatFailed: 'load the checks',
      action: () async {
        final all = await ref.read(apiProvider).moduleHooks();
        if (mounted) _hooks = all;
      },
    );
    if (mounted) setState(() => _loadError = ok ? null : actionError);
  }

  Future<void> _change(
    api.ModuleHook hook, {
    int? priority,
    bool? failClosed,
  }) async {
    setState(() => _busy = true);
    await guard(
      whatFailed: 'change the check',
      action: () async {
        final client = ref.read(apiProvider);
        await client.updateModuleHook(
          hook.moduleId,
          kind: hook.kind,
          hook: hook.hook,
          phase: hook.phase,
          priority: priority,
          failClosed: failClosed,
        );
        final all = await client.moduleHooks();
        if (mounted) _hooks = all;
      },
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = _loadError;
    if (error != null) {
      return SettingsSectionCard(
        title: 'Checks',
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(message: error, onRetry: _load),
          ),
        ],
      );
    }
    final mine = [
      for (final hook in _hooks ?? const <api.ModuleHook>[])
        if (hook.moduleId == widget.moduleId) hook,
    ];
    if (mine.isEmpty) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: 'Checks',
      description:
          'Lower numbers run first, and a failed check lets the action through.',
      children: [
        if (actionError case final message?)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(message: message, onDismiss: clearActionError),
          ),
        for (final hook in mine) ..._rows(hook),
      ],
    );
  }

  List<Widget> _rows(api.ModuleHook hook) => [
    SettingsDetailRow(
      icon: AppIcons.shield,
      title: dockHookTitle(hook),
      stackTrailingWhenNarrow: true,
      detail: hook.live
          ? dockHookRecord(hook)
          : 'Not in the chain: turn it on and approve it first.',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconButton(
            icon: AppIcons.moveUp,
            semanticLabel: 'Run earlier',
            tooltip: 'Run earlier',
            onPressed: _busy
                ? null
                : () => _change(
                    hook,
                    priority: hook.priority - dockHookPriorityStep,
                  ),
          ),
          AppIconButton(
            icon: AppIcons.moveDown,
            semanticLabel: 'Run later',
            tooltip: 'Run later',
            onPressed: _busy
                ? null
                : () => _change(
                    hook,
                    priority: hook.priority + dockHookPriorityStep,
                  ),
          ),
        ],
      ),
    ),
    SettingsToggleRow(
      label: 'Refuse if it fails',
      semanticLabel: 'Refuse if ${dockHookTitle(hook)} fails',
      value: hook.failClosed,
      onChanged: _busy ? null : (on) => _change(hook, failClosed: on),
    ),
  ];
}
