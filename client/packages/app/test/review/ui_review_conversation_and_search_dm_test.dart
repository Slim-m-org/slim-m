// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Direct-message conversations (your own notes, a person, a block either way)
/// and what a conversation shows when its channel cannot be opened.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/last_text_channel.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart' show AppPresence;
import 'package:slimm_app/src/providers/sync_controller.dart'
    show initialSyncCompleteProvider;
import 'package:slimm_data/data.dart' show DatabaseUnopenable, MessageStore;

import '../support/fake_blocks.dart';
import '../ui_snapshot_support.dart';
import 'ui_review_conversation_and_search_support.dart';

api.Message _dm(String channel, int seq, String author, String content) =>
    api.Message(
      id: '$channel-$seq',
      channelId: channel,
      authorId: author,
      authorDisplayName: author == 'user-nick' ? 'Nick' : 'Ada Lovelace',
      seq: seq,
      content: content,
      createdAt: 1753600000000 + (200 + seq) * 60000,
      editedAt: null,
    );

List<api.Message> _adaDm() => [
  ...fixtureMessages,
  _dm(
    'c-dm-ada',
    3,
    'user-ada',
    'It is the one under Channel settings > Permissions.',
  ),
  _dm(
    'c-dm-ada',
    4,
    'user-nick',
    'Found it. The grid is wider than I remembered.',
  ),
  _dm(
    'c-dm-ada',
    5,
    'user-ada',
    'It is, we trimmed the first column so the role names stop wrapping. Tell me if '
        'anything still clips at 800 wide, I can look again after lunch.',
  ),
];

const _notes = api.Channel(
  id: 'c-notes',
  name: 'Notes',
  kind: 'dm',
  createdAt: 0,
  dmParticipantId: 'user-nick',
  isPersonalSpace: true,
);

List<api.Message> _notesMessages() => [
  ...fixtureMessages,
  _dm('c-notes', 1, 'user-nick', 'Rotate the TURN credentials before Friday.'),
  _dm(
    'c-notes',
    2,
    'user-nick',
    'Ask Ada about the overwrites grid width at 800.',
  ),
  _dm(
    'c-notes',
    3,
    'user-nick',
    'Retro agenda: Friday demo vs Thursday, the call-audio USB drop, release notes owner.',
  ),
];

Future<void> _failedSend(MessageStore store) async {
  await store.addPending(
    id: 'p-failed',
    channelId: 'c-dm-ada',
    authorId: 'user-nick',
    content: 'hey, you around?',
  );
  await store.markFailed('p-failed', reason: 'Could not send that message.');
}

/// A switch the store provider reads, so one mount can start healthy and then lose its database.
class _StoreSwitch {
  bool failing = false;
}

final _storeSwitch = _StoreSwitch();

Override _switchableStore() {
  _storeSwitch.failing = false;
  return storeProvider.overrideWith((ref) async {
    final db = await ref.watch(databaseProvider.future);
    if (_storeSwitch.failing) throw const DatabaseUnopenable('denied');
    return MessageStore(db);
  });
}

/// Both states leave the id they opened on, so the frame is taken once the new route has landed.
Future<void> _followTheRedirect(ReviewRig rig) async {
  await rig.settle();
  await rig.settle();
}

final _syncDone = initialSyncCompleteProvider.overrideWith((ref) => true);

void main() {
  setUpAll(loadRealFonts);

  reviewCase(
    'channel-dm',
    state: 'personal-space',
    route: '/channels/c-notes',
    messages: _notesMessages,
    seed: (store) => store.upsertChannels([_notes]),
  );
  reviewCase(
    'channel-dm',
    state: 'blocked-by-me',
    route: '/channels/c-dm-ada',
    messages: _adaDm,
    overrides: () => [
      blocksProvider.overrideWith(
        (ref) => FixedBlocksController(
          ref,
          const BlocksState(ids: {'user-ada'}, settled: true),
        ),
      ),
    ],
  );
  reviewCase(
    'channel-dm',
    state: 'blocked-by-them',
    route: '/channels/c-dm-ada',
    messages: _adaDm,
    seed: _failedSend,
  );
  reviewCase(
    'channel-dm',
    state: 'one-to-one',
    route: '/channels/c-dm-ada',
    messages: _adaDm,
    overrides: () => [
      presenceForProvider('user-ada').overrideWith((ref) => AppPresence.online),
    ],
  );

  reviewCase(
    'state-conversation-unavailable',
    state: 'not-found',
    route: '/channels/c-unknown',
    overrides: () => [_syncDone],
    serve: (request) => request.url.path.endsWith('/thread-parent')
        ? jsonOk({'parent_deleted': false})
        : null,
  );
  reviewCase(
    'state-conversation-unavailable',
    state: 'unlisted-thread',
    route: '/channels/c-thread-unlisted',
    messages: () => [
      ...fixtureMessages,
      _dm('c-thread-unlisted', 1, 'user-ada', 'Good catch - filed as #341.'),
      _dm(
        'c-thread-unlisted',
        2,
        'user-nick',
        'Thanks, verifying the fix now.',
      ),
    ],
    overrides: () => [_syncDone],
    act: _followTheRedirect,
  );
  reviewCase(
    'state-conversation-unavailable',
    state: 'deleted',
    route: '/channels/c-planning',
    overrides: () => [
      _syncDone,
      deletedChannelsProvider.overrideWith((ref) => {'c-planning': 'planning'}),
      lastTextChannelProvider.overrideWith((ref) => 'c-general'),
    ],
    act: _followTheRedirect,
  );
  reviewCase(
    'state-conversation-unavailable',
    state: 'loading',
    route: '/channels/c-unknown',
    overrides: () => [_syncDone, reducedMotion()],
    serve: (request) => request.url.path.endsWith('/thread-parent')
        ? hangUntilTeardown()
        : null,
  );
  reviewCase(
    'state-conversation-unavailable',
    state: 'store-error',
    overrides: () => [_switchableStore()],
    act: (rig) async {
      _storeSwitch.failing = true;
      rig.container.invalidate(storeProvider);
      await rig.settle();
    },
  );
}
