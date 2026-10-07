// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' name and topic section: `PATCH /channels/{id}`
/// ([api.SlimmApiChannelAdmin]). Split out of the old `manage_channel_sheet`
/// that `channel_settings_screen.dart` replaced; unlike that sheet, this
/// section does not close its screen on a successful save, since the same
/// screen also carries permissions and delete - it reports success with a
/// toast instead (see `docs/design/desktop-vs-mobile.md` rule 6).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../char_count.dart';
import '../api_failure.dart';
import '../entity_name.dart';
import '../providers/providers.dart';
import '../providers/toasts.dart';
import '../widgets/settings_section_header.dart';

/// Matches the server's own ceiling (`CHANNEL_TOPIC_MAX_CHARS` in
/// `crates/slimm-server/src/http/channels.rs`), so the counter here never
/// disagrees with the length check the request will actually be judged
/// against.
const int channelTopicMaxChars = 256;

class ChannelGeneralSection extends ConsumerStatefulWidget {
  const ChannelGeneralSection({
    super.key,
    required this.channel,
    this.rows = const [],
  });

  final Channel channel;

  /// Settings that apply on their own (slow mode, join muted), under the save
  /// button in the same card, so one channel's general settings read as one list.
  final List<Widget> rows;

  @override
  ConsumerState<ChannelGeneralSection> createState() =>
      _ChannelGeneralSectionState();
}

class _ChannelGeneralSectionState extends ConsumerState<ChannelGeneralSection> {
  late final _name = TextEditingController(text: widget.channel.name);
  late final _topic = TextEditingController(text: widget.channel.topic ?? '');
  bool _saving = false;
  String? _error;
  // Tracked apart from widget.channel so a save resets "dirty" on its own.
  late String _savedName = widget.channel.name;
  late String _savedTopic = widget.channel.topic ?? '';

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _name.text.trim() != _savedName || _topic.text.trim() != _savedTopic;

  bool get _nameValid => entityNameValid(_name.text);

  bool get _topicValid => trimmedCharCount(_topic.text) <= channelTopicMaxChars;

  bool get _canSave => !_saving && _dirty && _nameValid && _topicValid;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await ref
          .read(apiProvider)
          .updateChannel(
            channelId: widget.channel.id,
            name: _name.text.trim(),
            topic: _topic.text,
          );
      final store = await ref.read(storeProvider.future);
      await store.upsertChannels([updated]);
      if (!mounted) return;
      setState(() {
        _savedName = updated.name;
        _savedTopic = updated.topic ?? '';
      });
      ref
          .read(toastsProvider.notifier)
          .show('Channel settings saved.', severity: AppToastSeverity.success);
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(() => _error = describeApiFailure('save the changes', e));
      }
    } finally {
      // Any escape, not just ApiException, must not wedge "Saving..." on.
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final topicLength = trimmedCharCount(_topic.text);

    return SettingsSectionCard(
      title: 'General',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppInput(
          controller: _name,
          placeholder: 'Channel name',
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
          // Enter saves, the same as the button below: the owner typed a new name, pressed it, and nothing happened.
          onSubmitted: (_) => _canSave ? unawaited(_save()) : null,
          semanticLabel: 'Channel name',
        ),
        const SizedBox(height: AppSpacing.s8),
        AppInput(
          controller: _topic,
          placeholder: 'Description',
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _canSave ? unawaited(_save()) : null,
          semanticLabel: 'Channel description',
        ),
        const SizedBox(height: AppSpacing.s4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '$topicLength/$channelTopicMaxChars',
            style: AppText.micro.copyWith(
              color: topicLength > channelTopicMaxChars
                  ? tokens.dangerText
                  : tokens.textSecondary,
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: _error!),
        ],
        const SizedBox(height: AppSpacing.s12),
        AppButton(
          label: _saving ? 'Saving...' : 'Save changes',
          variant: AppButtonVariant.primary,
          full: true,
          disabled: !_canSave,
          onPressed: _save,
        ),
        for (final row in widget.rows) ...[
          const SizedBox(height: AppSpacing.s12),
          row,
        ],
      ],
    );
  }
}
