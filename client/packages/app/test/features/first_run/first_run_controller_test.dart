// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The show-once decision: a new account sees setup, a returning account or
/// an old member does not, and skipping or finishing sticks across restarts.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/first_run/providers/first_run_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

final _now = DateTime.utc(2026, 10, 18, 12);

class _Server extends ChosenServer {
  @override
  Uri? build() => Uri.parse('https://space.test');
}

api.Me _me({Duration age = const Duration(minutes: 5), String id = 'u1'}) =>
    api.Me(
      id: id,
      username: 'new',
      displayName: 'New',
      createdAt: _now.subtract(age).millisecondsSinceEpoch,
      permissions: 0,
    );

class _Rig {
  _Rig._(this.db, this.store);
  final SlimmDatabase db;
  final MessageStore store;

  static _Rig create() {
    final db = SlimmDatabase(NativeDatabase.memory());
    return _Rig._(db, MessageStore(db));
  }

  ProviderContainer container(api.Me me) {
    final container = ProviderContainer(
      overrides: [
        meProvider.overrideWith((ref) => me),
        storeProvider.overrideWith((ref) => store),
        chosenServerProvider.overrideWith(_Server.new),
        firstRunClockProvider.overrideWithValue(() => _now),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }
}

Future<FirstRunState> _settled(ProviderContainer c) async {
  c.read(firstRunControllerProvider);
  await c.read(meProvider.future);
  await c.read(preferencesProvider.future);
  await pumpEventQueue();
  return c.read(firstRunControllerProvider);
}

void main() {
  late _Rig rig;

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    rig = _Rig.create();
  });
  tearDown(() => rig.db.close());

  test('a new account is shown setup', () async {
    final state = await _settled(rig.container(_me()));
    expect(state.active, isTrue);
  });

  test('an account older than a day is not', () async {
    final state = await _settled(
      rig.container(_me(age: const Duration(days: 3))),
    );
    expect(state.active, isFalse);
  });

  test('an account that already wrote a message is not', () async {
    await rig.store.addPending(
      id: 'm1',
      channelId: 'c1',
      authorId: 'u1',
      content: 'hi',
    );
    final state = await _settled(rig.container(_me()));
    expect(state.active, isFalse);
  });

  test('skipping persists across a restart', () async {
    final first = rig.container(_me());
    expect((await _settled(first)).active, isTrue);
    await first.read(firstRunControllerProvider.notifier).complete();
    expect(first.read(firstRunControllerProvider).active, isFalse);

    final restarted = await _settled(rig.container(_me()));
    expect(restarted.active, isFalse);
    expect(restarted.voiceHint, isFalse);
  });

  test('finishing arms the voice hint until it is dismissed', () async {
    final first = rig.container(_me());
    await _settled(first);
    final controller = first.read(firstRunControllerProvider.notifier);
    await controller.complete(voiceHint: true);
    expect(first.read(firstRunControllerProvider).voiceHint, isTrue);

    final restarted = rig.container(_me());
    expect((await _settled(restarted)).voiceHint, isTrue);

    await restarted
        .read(firstRunControllerProvider.notifier)
        .dismissVoiceHint();
    final again = await _settled(rig.container(_me()));
    expect(again.voiceHint, isFalse);
  });

  test('setup is tracked per account on the same device', () async {
    final first = rig.container(_me());
    await _settled(first);
    await first.read(firstRunControllerProvider.notifier).complete();

    final other = await _settled(rig.container(_me(id: 'u2')));
    expect(other.active, isTrue);
  });

  test('running setup again writes nothing and leaves no hint', () async {
    final c = rig.container(_me(age: const Duration(days: 9)));
    await _settled(c);
    final controller = c.read(firstRunControllerProvider.notifier);
    controller.replay();
    expect(c.read(firstRunControllerProvider).replay, isTrue);
    await controller.complete(voiceHint: true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
    expect(c.read(firstRunControllerProvider).voiceHint, isFalse);
  });
}
