// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The optional welcome message, in Space settings' Invites pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../channels/providers/channel_permissions.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/space_settings.dart';
import 'settings_field.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';
import '../providers/settings_actions.dart';
import '../../../widgets/load_error_block.dart';

const _sectionLabel = 'Welcome message';

const _placeholders = '{user} mentions the new member, {space} is the name.';

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
          LoadErrorBlock(
            message: 'Could not load the welcome message.',
            onRetry: () => ref.invalidate(spaceSettingsProvider),
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
  String? _channelError;
  String? _messageError;

  /// Null from a server that predates the default and still requires a message.
  String? get _defaultMessage => widget.initial.welcomeDefaultMessage;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final message = _message.text.trim();
    final channelError = _enabled && _channel == _noChannel
        ? 'Pick a channel to turn this on.'
        : null;
    final messageError = _enabled && message.isEmpty && _defaultMessage == null
        ? 'Write a message to turn this on.'
        : null;
    setState(() {
      _channelError = channelError;
      _messageError = messageError;
    });
    if (channelError != null || messageError != null) return;
    setState(() => _saving = true);
    final ok = await guard(
      whatFailed: 'save the welcome message',
      action: () => ref
          .read(settingsActionsProvider)
          .setSpaceSettings(
            api.SpaceSettingsUpdate(
              welcomeEnabled: _enabled,
              welcomeChannelId: _channel,
              welcomeMessage: message,
            ),
          ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) ref.invalidate(spaceSettingsProvider);
  }

  void _setEnabled(bool value) => setState(() {
    _enabled = value;
    _channelError = null;
    _messageError = null;
  });

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
          onChanged: _saving ? null : _setEnabled,
        ),
        SettingsSelectRow<String>(
          label: 'Welcome channel',
          value: choices.any((c) => c.value == _channel)
              ? _channel
              : _noChannel,
          choices: choices,
          sheetTitle: 'Welcome channel',
          onChanged: (v) => setState(() {
            _channel = v;
            _channelError = null;
          }),
          errorText: _channelError,
        ),
        SettingsCardBlock(
          children: [
            SettingsField(
              label: 'Message',
              helper: _defaultMessage == null
                  ? _placeholders
                  : 'Leave empty for the default. $_placeholders',
              child: AppInput(
                controller: _message,
                placeholder: _defaultMessage,
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
