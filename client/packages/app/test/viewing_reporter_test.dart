// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a device tells the server it has open: only channels shown in a
/// focused window, refreshed while they stay open, and cleared the moment
/// nothing is in front of the user.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/mounted_channels.dart';
import 'package:slimm_app/src/providers/viewing_reporter.dart';

final _focus = StateProvider<bool>((ref) => true);

void main() {
  late ProviderContainer container;
  late List<Set<String>> sent;
  late List<bool> actives;
  late ViewingReporter reporter;

  setUp(() {
    container = ProviderContainer(
      overrides: [appFocusedProvider.overrideWith((ref) => ref.watch(_focus))],
    );
    sent = [];
    actives = [];
    reporter = container.read(
      Provider((ref) {
        return ViewingReporter(
          ref,
          send: (channels, active) {
            sent.add(channels);
            actives.add(active);
          },
          interval: const Duration(seconds: 30),
        );
      }),
    );
  });
  tearDown(() {
    reporter.dispose();
    container.dispose();
  });

  test('opening a channel reports it, and closing it reports nothing', () {
    final mounted = container.read(mountedChannelsProvider);
    mounted.register('c1');
    expect(sent, [
      {'c1'},
    ]);
    mounted.unregister('c1');
    expect(sent.last, isEmpty);
  });

  test('a window without focus reports nothing even with a channel open', () {
    final mounted = container.read(mountedChannelsProvider)..register('c1');
    container.read(_focus.notifier).state = false;
    reporter.refresh();
    expect(sent.last, isEmpty, reason: 'other devices must still be pushed to');
    mounted.unregister('c1');
  });

  test('an open channel is re-reported inside the server lapse', () {
    fakeAsync((async) {
      container.read(mountedChannelsProvider).register('c1');
      sent.clear();
      async.elapse(const Duration(seconds: 61));
      expect(sent, [
        {'c1'},
        {'c1'},
      ]);
    });
  });

  test('a device that never opened anything stays silent', () {
    reporter.refresh();
    expect(sent, isEmpty);
  });

  test(
    'input marks the device active even with no channel open, until the window lapses',
    () {
      fakeAsync((async) {
        reporter.noteInput();
        expect(sent.last, isEmpty);
        expect(actives.last, isTrue, reason: 'a settings screen still counts');
        async.elapse(const Duration(seconds: 61));
        expect(actives.last, isTrue, reason: 're-sent inside the server lapse');
        async.elapse(activeInputWindow);
        expect(actives.last, isFalse, reason: 'walking away restores push');
        final count = sent.length;
        async.elapse(const Duration(minutes: 5));
        expect(sent.length, count, reason: 'an idle device goes quiet again');
      });
    },
  );

  test('input in an unfocused window is not activity', () {
    container.read(_focus.notifier).state = false;
    reporter.noteInput();
    expect(actives, isNot(contains(true)));
  });

  test('a focused window with a channel open but no input is not active', () {
    container.read(mountedChannelsProvider).register('c1');
    expect(actives.last, isFalse);
  });
}
