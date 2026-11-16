// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The levels a channel's default notification row offers in channel settings.
library;

import 'package:slimm_api/api.dart' as api;

import '../../settings/widgets/settings_select_row.dart';

const _mentionsOnly = SettingsChoice(
  value: api.NotificationPreference.mentions,
  label: 'Mentions only',
);
const _muted = SettingsChoice(
  value: api.NotificationPreference.nothing,
  label: 'Muted',
);

const channelDefaultNotificationChoices = [
  SettingsChoice(
    value: api.NotificationPreference.everything,
    label: 'All messages',
  ),
  _mentionsOnly,
  _muted,
];

/// A voice channel's chat is never louder than mentions until a member opts in.
const voiceChannelDefaultNotificationChoices = [_mentionsOnly, _muted];

const channelDefaultNotificationLabel = 'Default notifications';
const channelDefaultNotificationHint = 'What members get until they choose.';
