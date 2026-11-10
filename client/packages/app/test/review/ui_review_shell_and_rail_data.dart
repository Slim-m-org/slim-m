// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The busy Space the rail review captures run against: several categories, a
/// long channel name, voice rooms, DMs with a long name, and a spread of read
/// state, in place of the fixture's three-channel list.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

import 'ui_review_shell_and_rail_actions.dart';
import 'ui_review_shell_and_rail_support.dart';

const _categories = [
  api.ChannelCategory(id: 'cat-text', name: 'Text', position: 0, createdAt: 0),
  api.ChannelCategory(
    id: 'cat-voice',
    name: 'Voice',
    position: 1,
    createdAt: 0,
  ),
  api.ChannelCategory(
    id: 'cat-projects',
    name: 'Projects',
    position: 2,
    createdAt: 0,
  ),
  api.ChannelCategory(
    id: 'cat-archive',
    name: 'Archive',
    position: 3,
    createdAt: 0,
  ),
];

api.Channel _text(
  String id,
  String name,
  String category,
  int position, {
  String? topic,
}) => api.Channel(
  id: 'c-$id',
  name: name,
  kind: 'text',
  createdAt: 0,
  categoryId: category,
  position: position,
  topic: topic,
);

api.Channel _voice(
  String id,
  String name,
  int position, {
  bool muted = false,
}) => api.Channel(
  id: 'c-$id',
  name: name,
  kind: 'voice',
  createdAt: 0,
  categoryId: 'cat-voice',
  position: position,
  joinMuted: muted,
);

final _channels = [
  _text(
    'general',
    'general',
    'cat-text',
    0,
    topic:
        'General chat for the whole Space - keep it friendly, and keep '
        'call logistics in #main instead of here.',
  ),
  _text('design', 'design', 'cat-text', 1, topic: 'tokens, type and the shell'),
  _text('announcements', 'announcements', 'cat-text', 2),
  _text('roadmap', 'release-planning-and-roadmap-discussion', 'cat-text', 3),
  _text('random', 'random', 'cat-text', 4),
  _voice('main', 'main', 0, muted: true),
  _voice('lounge', 'Lounge', 1),
  _voice('pairing', 'Pair programming', 2),
  // A locked room with a user limit, owned by someone else.
  const api.Channel(
    id: 'c-room-ada',
    name: "Ada's room",
    kind: 'voice',
    createdAt: 0,
    categoryId: 'cat-voice',
    position: 4,
    roomOwnerId: 'user-ada',
    roomLocked: true,
    userLimit: 4,
  ),
  // A temporary room its creator owns: the only voice row whose menu offers Room options.
  const api.Channel(
    id: 'c-room-nick',
    name: "Nick's room",
    kind: 'voice',
    createdAt: 0,
    categoryId: 'cat-voice',
    position: 3,
    roomOwnerId: 'user-nick',
  ),
  _text('backend', 'sparrow-backend', 'cat-projects', 0),
  _text('client', 'sparrow-client', 'cat-projects', 1),
  _text('reviews', 'sparrow-design-reviews', 'cat-projects', 2),
  _text('old', 'old-announcements', 'cat-archive', 0),
  _text('bots', 'retired-bots', 'cat-archive', 1),
  const api.Channel(
    id: 'c-dm-ada',
    name: 'Ada Lovelace',
    kind: 'dm',
    createdAt: 0,
    dmParticipantId: 'user-ada',
  ),
  const api.Channel(
    id: 'c-dm-group',
    name: 'Ada and Christoph',
    kind: 'dm',
    createdAt: 0,
    dmMemberIds: ['user-nick', 'user-ada', 'user-long-name'],
  ),
  const api.Channel(
    id: 'c-notes',
    name: 'Nick',
    kind: 'dm',
    createdAt: 0,
    isPersonalSpace: true,
    dmParticipantId: 'user-nick',
  ),
  const api.Channel(
    id: 'c-dm-christoph',
    name: 'Christoph Bartholomew Fitzgerald-Huang III',
    kind: 'dm',
    createdAt: 0,
    dmParticipantId: 'user-long-name',
  ),
];

/// Grows the fixture's list into a busy one: four categories, two temporary rooms and four DMs.
Future<void> seedBusyRail(WidgetTester tester, ShellScene scene) async {
  final store = await scene.container.read(storeProvider.future);
  // The uncategorised fixture channel would add a "Channels" section nothing here is about.
  await store.removeChannel('c-empty');
  await store.replaceCategories(_categories);
  await store.upsertChannels(_channels);
}

/// [seedBusyRail] with read state across it: a plain unread, mentions, an old backlog and a read channel.
Future<void> seedBusyRailWithUnread(
  WidgetTester tester,
  ShellScene scene,
) async {
  await seedBusyRail(tester, scene);
  await markChannel(scene, 'c-general', cursor: 14, lastRead: 9);
  await markChannel(scene, 'c-design', cursor: 8, lastRead: 8);
  await markChannel(
    scene,
    'c-announcements',
    cursor: 12,
    lastRead: 6,
    mentioned: 12,
  );
  await markChannel(scene, 'c-roadmap', cursor: 120, lastRead: 40);
  await markChannel(scene, 'c-random', cursor: 31, lastRead: 20);
  await markChannel(scene, 'c-backend', cursor: 7, lastRead: 2, mentioned: 7);
  await markChannel(scene, 'c-pairing', cursor: 5, lastRead: 1);
  await markChannel(scene, 'c-dm-ada', cursor: 4, lastRead: 1);
}
