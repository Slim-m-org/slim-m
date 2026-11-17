// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a palette message hit says it was said.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart'
    show paletteHitChannelLabel;
import 'package:slimm_data/data.dart';

const _general = Channel(
  id: 'c1',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

api.Message _hit({required String channelId, String? threadParentChannelId}) =>
    api.Message(
      id: 'm1',
      channelId: channelId,
      authorId: 'u1',
      authorDisplayName: 'U',
      seq: 1,
      content: 'hi',
      createdAt: 0,
      editedAt: null,
      threadParentChannelId: threadParentChannelId,
    );

void main() {
  test('a hit in a channel names the channel', () {
    expect(
      paletteHitChannelLabel(_hit(channelId: 'c1'), const {'c1': _general}),
      '#general',
    );
  });

  test('a hit inside a thread names the channel it hangs off', () {
    expect(
      paletteHitChannelLabel(
        _hit(channelId: 't1', threadParentChannelId: 'c1'),
        const {'c1': _general},
      ),
      'a thread in #general',
    );
  });
}
