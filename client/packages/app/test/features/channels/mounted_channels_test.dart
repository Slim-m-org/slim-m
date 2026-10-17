// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [MountedChannels] is the registry `retention_sweep.dart` reads to know
/// which channels a sweep must never prune past their live window - the one
/// answer nothing in the app had before it existed (`retention_policy.dart`'s
/// own doc names `channelHistoryProvider` as never disposed, so its presence
/// says nothing about whether a channel is genuinely open).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/mounted_channels.dart';

void main() {
  test('a registered channel is open', () {
    final channels = MountedChannels();

    channels.register('c1');

    expect(channels.openChannelIds, {'c1'});
  });

  test('unregistering the only registration closes the channel', () {
    final channels = MountedChannels();
    channels.register('c1');

    channels.unregister('c1');

    expect(channels.openChannelIds, isEmpty);
  });

  test('a channel held open by two callers survives one of them leaving', () {
    final channels = MountedChannels();
    channels.register('c1');
    channels.register('c1');

    channels.unregister('c1');

    expect(
      channels.openChannelIds,
      {'c1'},
      reason:
          'a route transition can hold two ChannelScreens on the same '
          'channel for a moment; the first to dispose must not close it',
    );

    channels.unregister('c1');
    expect(channels.openChannelIds, isEmpty);
  });

  test('unregistering a channel nobody registered is a no-op', () {
    final channels = MountedChannels();

    channels.unregister('never-opened');

    expect(channels.openChannelIds, isEmpty);
  });

  test('unrelated channels track independently', () {
    final channels = MountedChannels();
    channels.register('c1');
    channels.register('c2');

    channels.unregister('c1');

    expect(channels.openChannelIds, {'c2'});
  });
}
