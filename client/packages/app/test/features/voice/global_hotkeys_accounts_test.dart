// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The OS keeps one global shortcut set, so viewing another account never
/// rebinds it away from the account in the call.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/global_hotkeys_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';

import '../accounts/account_host_harness.dart';
import 'global_hotkeys_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  late FakeHotkeySource source;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.push_to_talk_enabled': true,
    });
    source = FakeHotkeySource();
    h = AccountHarness(
      extraOverrides: [globalHotkeySourceProvider.overrideWithValue(source)],
    );
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
  });

  tearDown(() => h.dispose());

  test(
    'viewing another account does not take the shortcuts from the call',
    () async {
      final first = h.host.runtimeFor(_a)!.container;
      final second = h.host.runtimeFor(_b)!.container;
      first.read(globalHotkeysProvider);
      await pumpEventQueueTimes();
      expect(source.binds, hasLength(1));

      first.read(testCallProvider.notifier).state = connectedCall;
      await h.host.switchTo(_b);
      second.read(globalHotkeysProvider);
      await pumpEventQueueTimes();

      expect(
        source.binds,
        hasLength(1),
        reason: 'the call account still owns it',
      );
    },
  );

  test('the shortcuts follow the call back to the account on screen', () async {
    final first = h.host.runtimeFor(_a)!.container;
    final second = h.host.runtimeFor(_b)!.container;
    first.read(globalHotkeysProvider);
    await pumpEventQueueTimes();
    first.read(testCallProvider.notifier).state = connectedCall;
    await h.host.switchTo(_b);
    second.read(globalHotkeysProvider);
    await pumpEventQueueTimes();

    first.read(testCallProvider.notifier).state = const VoiceFlags();
    await pumpEventQueueTimes();

    expect(source.binds, hasLength(2));
  });
}
