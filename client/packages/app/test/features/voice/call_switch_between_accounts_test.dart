// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call started in one account ends the other account's call first, so its
/// teardown cannot land on the new call's foreground service and call entry.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/accounts/providers/account_store.dart';
import 'package:slimm_platform/testing.dart' show InMemoryKeyStore;
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _LoggedSession extends FakeSession {
  _LoggedSession(this.name, this.events);

  final String name;
  final List<String> events;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) {
    events.add('$name joined');
    return super.join(url: url, token: token);
  }

  @override
  Future<void> leave() async {
    await super.leave();
    events.add('$name left');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = VoiceHarness();
  final second = VoiceHarness();
  tearDown(() {
    first.dispose();
    second.dispose();
  });

  test('the other account has left before the new call connects', () async {
    final events = <String>[];
    final host = AccountHost(
      store: AccountStore(InMemoryKeyStore()),
      createContainer: (_) => throw UnimplementedError(),
      startServices: (_) async {},
      onActivate: (_) async {},
      readSession: (_) async => true,
      signOutRuntime: (_) async {},
    );
    addTearDown(host.dispose);
    final overrides = [accountHostProvider.overrideWithValue(host)];
    final firstSession = _LoggedSession('first', events);
    final inCall = first.controllerWith(
      firstSession,
      voiceApi(),
      extraOverrides: overrides,
    );
    final joining = second.controllerWith(
      _LoggedSession('second', events),
      voiceApi(),
      extraOverrides: overrides,
    );
    AccountSlot slot() =>
        AccountSlot(chooseServer: (_, _) => throw UnimplementedError());
    host.adoptFirst(first.container, slot()).inCall = true;
    host.adoptFirst(second.container, slot());
    await inCall.join('channel-1');
    firstSession.emitState(VoiceSessionState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(inCall.state.state, VoiceSessionState.connected);
    events.clear();

    await joining.join('channel-2');
    await Future<void>.delayed(Duration.zero);

    expect(events, ['first left', 'second joined']);
    expect(inCall.state.channelId, isNull);
  });
}
