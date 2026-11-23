// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Call stats pane's half of the settings search index; see `settings_index.dart`.
library;

import 'settings_index.dart';

const callStatsPane = 'call-stats';

const callStatsSettingsIndex = <SettingsEntry>[
  SettingsEntry(
    callStatsPane,
    'Talk time',
    description: 'Only you can see these.',
    keywords: [
      'stats',
      'speech',
      'words per minute',
      'pace',
      'calls',
      'speaking',
    ],
    gate: SettingsGate.callTranscripts,
    conditional: true,
  ),
  SettingsEntry(
    callStatsPane,
    'Filler words',
    description:
        'English only, as the transcriber leaves out most ums and uhs.',
    keywords: ['filler', 'um', 'uh', 'like', 'you know', 'speech', 'stats'],
    gate: SettingsGate.callTranscripts,
    conditional: true,
  ),
  SettingsEntry(
    callStatsPane,
    'Languages',
    keywords: ['language', 'speech', 'stats', 'words per minute'],
    gate: SettingsGate.callTranscripts,
    conditional: true,
  ),
  SettingsEntry(
    callStatsPane,
    'Talk time by day',
    keywords: ['chart', 'week', 'stats', 'speech'],
    gate: SettingsGate.callTranscripts,
    conditional: true,
  ),
];
