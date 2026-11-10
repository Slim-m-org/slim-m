// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The numbers and rows the Space pane review cases answer with, shaped like
/// the server's own replies.
library;

import 'package:slimm_api/api.dart' as api;

import 'ui_review_settings_personal_and_space_support.dart';

typedef ReviewAnswerSet = Map<String, ReviewAnswer>;

final _now = DateTime.now().millisecondsSinceEpoch;

int _ago({int minutes = 0, int hours = 0, int days = 0}) =>
    _now - ((days * 24 + hours) * 60 + minutes) * 60000;

/// Screen share and noise defaults, with [results] as the kept uplink tests.
ReviewAnswerSet voiceAnswers({required List<Map<String, Object?>> results}) => {
  '/space/screen-share': jsonAnswer({'max_height': 1440}),
  '/space/settings': jsonAnswer({
    'name': 'Pine Hollow',
    'join_policy': 'invite',
    'strong_noise_suppression': true,
  }),
  'GET /space/uplink-test': jsonAnswer({'results': results}),
};

final uplinkResults = <Map<String, Object?>>[
  {
    'id': 3,
    'measured_at': _ago(hours: 2),
    'mbit_per_s': 187.4,
    'bytes': 41943040,
    'duration_ms': 1790,
  },
  {
    'id': 2,
    'measured_at': _ago(days: 3),
    'mbit_per_s': 92.1,
    'bytes': 41943040,
    'duration_ms': 3643,
  },
  {
    'id': 1,
    'measured_at': _ago(days: 9),
    'mbit_per_s': 41.6,
    'bytes': 41943040,
    'duration_ms': 8066,
  },
];

final runningExport = api.DataExport(
  id: 'e-run',
  kind: api.ExportKind.space,
  status: api.ExportStatus.running,
  processed: 4210,
  total: 9800,
  createdAt: _ago(minutes: 6),
);

final readyExport = api.DataExport(
  id: 'e-ready',
  kind: api.ExportKind.space,
  status: api.ExportStatus.ready,
  processed: 9800,
  total: 9800,
  sizeBytes: 183500800,
  createdAt: _ago(hours: 1),
  finishedAt: _ago(minutes: 40),
  expiresAt: _now + 23 * 3600000,
);

Map<String, Object?> _change(
  int id,
  String actor,
  String action,
  String target,
  Map<String, Object?> detail,
  int at,
) => {
  'id': id,
  'actor_id': actor,
  'action': action,
  'target_id': target,
  'detail': detail,
  'created_at': at,
};

final auditEntries = <Map<String, Object?>>[
  _change(8, 'user-nick', 'role.update', 'role-mod', {
    'name': 'Moderator',
    'fields': ['permissions'],
  }, _ago(minutes: 4)),
  _change(7, 'user-ada', 'channel.create', 'c-design', {
    'name': 'design',
  }, _ago(minutes: 38)),
  _change(6, 'user-nick', 'invite.create', 'inv-1', {}, _ago(hours: 3)),
  _change(5, 'user-nick', 'space.retention', 'space', {}, _ago(hours: 7)),
  _change(4, 'user-ada', 'emoji.create', 'emoji-1', {
    'name': 'party_parrot',
  }, _ago(days: 1)),
  _change(3, 'user-nick', 'channel.delete', 'c-old', {
    'name': 'old-news',
  }, _ago(days: 2)),
  _change(2, 'user-nick', 'role.assign', 'user-ada', {
    'params': {'role_id': 'role-mod'},
  }, _ago(days: 4)),
  _change(1, 'user-nick', 'space.update', 'space', {
    'fields': ['name'],
  }, _ago(days: 6)),
];

final customizedSpace = <String, Object?>{
  'name': 'Pine Hollow',
  'join_policy': 'invite',
  'description':
      'A small community for people who build things together and '
      'talk about it afterwards.',
  'banner_updated_at': 1,
  'welcome_enabled': true,
  'welcome_channel_id': 'c-general',
  'welcome_message': 'Welcome in. Say hi in #general and pick a role.',
};

final storageReport = {
  'database_bytes': 52428800,
  'database_reclaimable_bytes': 3145728,
  'attachment_bytes': 734003200,
  'top_channels': [
    {'channel_id': 'c1', 'name': 'screenshots', 'attachment_bytes': 419430400},
    {'channel_id': 'c2', 'name': 'general', 'attachment_bytes': 209715200},
    {'channel_id': 'c3', 'name': 'memes', 'attachment_bytes': 104857600},
  ],
  'sweeps': [
    {'name': 'token', 'last_run_at': _ago(hours: 3), 'last_reclaimed': 3},
    {'name': 'attachments', 'last_run_at': _ago(hours: 3), 'last_reclaimed': 0},
  ],
  'backup': {
    'state': 'verified',
    'stale': false,
    'verified_at': _ago(hours: 9),
    'verified_bytes': 52428800,
  },
};

const setupReport = {
  'claimed_by_me': true,
  'completed': true,
  'capacity': {
    'cores': 4,
    'voice_configured': true,
    'memory_total_bytes': 8589934592,
    'memory_limit_bytes': 2147483648,
    'disk_free_bytes': 214748364800,
    'disk_total_bytes': 536870912000,
    'estimate': {
      'binding': 'memory',
      'connection_limit': 5000,
      'members_min': 150,
      'members_max': 400,
      'voice_min': 8,
      'voice_max': 20,
    },
  },
};

const metrics = api.ServerMetrics(
  residentMemoryBytes: 94371840,
  webSocketConnections: 12,
  requestsByClass: [
    api.RequestClassCount(className: 'read', admitted: 5120, refused: 0),
    api.RequestClassCount(className: 'write', admitted: 840, refused: 6),
    api.RequestClassCount(className: 'upload', admitted: 31, refused: 0),
  ],
  pool: api.DbPoolStats(max: 8, size: 8, inUse: 3),
  routes: [
    api.RouteMetric(
      method: 'GET',
      route: '/channels/{id}/messages',
      count: 4210,
      sumSeconds: 126.3,
      p95Seconds: 0.082,
    ),
    api.RouteMetric(
      method: 'POST',
      route: '/channels/{id}/messages',
      count: 640,
      sumSeconds: 30.7,
      p95Seconds: 0.21,
    ),
  ],
);
