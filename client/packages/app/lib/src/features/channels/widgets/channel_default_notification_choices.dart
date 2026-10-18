// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The levels a channel's default notification row offers, shared by the
/// create sheet and the channel settings.
library;

import 'package:slimm_api/api.dart' as api;

import '../../settings/widgets/settings_select_row.dart';

const channelDefaultNotificationChoices = [
  SettingsChoice(
    value: api.NotificationPreference.everything,
    label: 'All messages',
  ),
  SettingsChoice(
    value: api.NotificationPreference.mentions,
    label: 'Mentions only',
  ),
  SettingsChoice(value: api.NotificationPreference.nothing, label: 'Muted'),
];

const channelDefaultNotificationLabel = 'Default notifications';
const channelDefaultNotificationHint = 'What members get until they choose.';
