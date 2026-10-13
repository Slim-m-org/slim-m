// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join gate and raid mode, in Space settings' Invites pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_permissions.dart';
import '../providers/join_gate_providers.dart';
import '../providers/providers.dart';
import 'labeled_field.dart';
import 'run_guarded.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';

/// The rules channel choice for "none".
const _noChannel = '';

class JoinGateSection extends ConsumerWidget {
  const JoinGateSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = ref.watch(joinGateProvider);
    return gate.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => AppErrorState(
        message: 'Could not load the join gate.',
        onRetry: () => ref.invalidate(joinGateProvider),
      ),
      data: (loaded) => _JoinGateForm(initial: loaded),
    );
  }
}

class _JoinGateForm extends ConsumerStatefulWidget {
  const _JoinGateForm({required this.initial});

  final api.JoinGate initial;

  @override
  ConsumerState<_JoinGateForm> createState() => _JoinGateFormState();
}

class _JoinGateFormState extends ConsumerState<_JoinGateForm>
    with GuardedActionState<_JoinGateForm> {
  late bool _enabled = widget.initial.enabled;
  late bool _paused = widget.initial.joinsPaused;
  late String _channel = widget.initial.rulesChannelId ?? _noChannel;
  late final _rules = TextEditingController(text: widget.initial.rules);
  bool _saving = false;
  String? _rulesError;

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final rules = _rules.text.trim();
    if (_enabled && rules.isEmpty) {
      setState(() => _rulesError = 'Write the rules before turning this on.');
      return;
    }
    setState(() {
      _saving = true;
      _rulesError = null;
    });
    final gate = api.JoinGate(
      enabled: _enabled,
      rules: rules,
      rulesChannelId: _channel == _noChannel ? null : _channel,
      joinsPaused: _paused,
    );
    final ok = await guard(
      whatFailed: 'save the join gate',
      action: () => ref.read(apiProvider).setJoinGate(gate),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) ref.invalidate(joinGateProvider);
  }

  @override
  Widget build(BuildContext context) {
    final channels =
        ref.watch(myVisibleChannelsProvider).valueOrNull ?? const [];
    final textChannels = channels.where((c) => c.kind == 'text');
    final choices = [
      const SettingsChoice(value: _noChannel, label: 'None'),
      for (final c in textChannels)
        SettingsChoice(value: c.id, label: '#${c.name}'),
    ];
    final error = actionError;
    return SettingsSectionCard(
      title: 'Join gate',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Gate new members',
          description:
              'Until they accept the rules, they can only read the rules channel.',
          semanticLabel: 'Gate new members',
          value: _enabled,
          onChanged: _saving ? null : (v) => setState(() => _enabled = v),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s8,
            AppSpacing.s12,
            AppSpacing.s8,
            AppSpacing.s4,
          ),
          child: LabeledField(
            label: 'Rules',
            child: AppInput(
              controller: _rules,
              placeholder: 'Be kind. No spam.',
              minLines: 4,
              maxLines: 12,
              counterMax: api.InputLimits.spaceRules,
              keyboardType: TextInputType.multiline,
              errorText: _rulesError,
              semanticLabel: 'Rules',
            ),
          ),
        ),
        SettingsSelectRow<String>(
          label: 'Rules channel',
          value: choices.any((c) => c.value == _channel)
              ? _channel
              : _noChannel,
          choices: choices,
          sheetTitle: 'Rules channel',
          onChanged: (v) => setState(() => _channel = v),
        ),
        SettingsToggleRow(
          label: 'Pause new members',
          description: 'Nobody new can join, even with an invite.',
          semanticLabel: 'Pause new members',
          value: _paused,
          onChanged: _saving ? null : (v) => setState(() => _paused = v),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: AppErrorState(message: error, onDismiss: clearActionError),
          ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Save',
              variant: AppButtonVariant.primary,
              busy: _saving,
              onPressed: _save,
            ),
          ),
        ),
      ],
    );
  }
}
