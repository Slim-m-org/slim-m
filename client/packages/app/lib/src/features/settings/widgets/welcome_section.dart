// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The optional welcome message, in Space settings' Invites pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../channels/providers/channel_permissions.dart';
import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import 'join_policy_row.dart' show spaceSettingsProvider;
import 'settings_field.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';

const _sectionLabel = 'Welcome message';

/// The channel choice for "none".
const _noChannel = '';

class WelcomeSection extends ConsumerWidget {
  const WelcomeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(spaceSettingsProvider);
    return settings.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => SettingsSectionCard(
        title: _sectionLabel,
        children: [
          SettingsCardBlock(
            children: [
              AppErrorState(
                message: 'Could not load the welcome message.',
                onRetry: () => ref.invalidate(spaceSettingsProvider),
              ),
            ],
          ),
        ],
      ),
      data: (loaded) => _WelcomeForm(initial: loaded),
    );
  }
}

class _WelcomeForm extends ConsumerStatefulWidget {
  const _WelcomeForm({required this.initial});

  final api.SpaceSettings initial;

  @override
  ConsumerState<_WelcomeForm> createState() => _WelcomeFormState();
}

class _WelcomeFormState extends ConsumerState<_WelcomeForm>
    with GuardedActionState<_WelcomeForm> {
  late bool _enabled = widget.initial.welcomeEnabled;
  late String _channel = widget.initial.welcomeChannelId ?? _noChannel;
  late final _message = TextEditingController(
    text: widget.initial.welcomeMessage,
  );
  bool _saving = false;
  String? _messageError;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final message = _message.text.trim();
    if (_enabled && (message.isEmpty || _channel == _noChannel)) {
      setState(
        () => _messageError =
            'Pick a channel and write a message to turn this on.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _messageError = null;
    });
    final ok = await guard(
      whatFailed: 'save the welcome message',
      action: () => ref
          .read(apiProvider)
          .setSpaceSettings(
            welcomeEnabled: _enabled,
            welcomeChannelId: _channel,
            welcomeMessage: message,
          ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) ref.invalidate(spaceSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final channels =
        ref.watch(myVisibleChannelsProvider).valueOrNull ?? const [];
    final choices = [
      const SettingsChoice(value: _noChannel, label: 'None'),
      for (final c in channels.where((c) => c.kind == 'text'))
        SettingsChoice(value: c.id, label: '#${c.name}'),
    ];
    final error = actionError;
    return SettingsSectionCard(
      title: _sectionLabel,
      children: [
        SettingsToggleRow(
          label: 'Welcome new members',
          description: 'Posts once in a channel when someone joins.',
          semanticLabel: 'Welcome new members',
          value: _enabled,
          onChanged: _saving ? null : (v) => setState(() => _enabled = v),
        ),
        SettingsSelectRow<String>(
          label: 'Welcome channel',
          value: choices.any((c) => c.value == _channel)
              ? _channel
              : _noChannel,
          choices: choices,
          sheetTitle: 'Welcome channel',
          onChanged: (v) => setState(() => _channel = v),
        ),
        SettingsCardBlock(
          children: [
            SettingsField(
              label: 'Message',
              helper: '{user} mentions the new member, {space} is the name.',
              child: AppInput(
                controller: _message,
                placeholder: 'Welcome to {space}, {user}!',
                minLines: 2,
                maxLines: 6,
                counterMax: api.InputLimits.welcomeMessage,
                keyboardType: TextInputType.multiline,
                errorText: _messageError,
                semanticLabel: _sectionLabel,
              ),
            ),
            if (error != null)
              AppErrorState(message: error, onDismiss: clearActionError),
            Align(
              alignment: Alignment.centerRight,
              child: AppButton(
                label: 'Save',
                variant: AppButtonVariant.primary,
                busy: _saving,
                onPressed: _save,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
