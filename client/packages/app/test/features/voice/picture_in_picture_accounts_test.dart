// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picture-in-picture is one window per process: viewing another account
/// leaves the call owner's eligibility and window state alone.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/picture_in_picture.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_platform/platform.dart';

import '../accounts/account_host_harness.dart';

const _channelName = 'top.npcserver.slimm/picture_in_picture';
const _a = 'https://first.example';
const _b = 'https://second.example';

final _eligible = StateProvider<bool>((ref) => false);

List<Override> _overrides() => [
  pictureInPictureEligibleProvider.overrideWith((ref) => ref.watch(_eligible)),
  pictureInPictureChannelProvider.overrideWith((ref) {
    final channel = PictureInPictureChannel(isAndroid: true);
    ref.onDispose(channel.dispose);
    return channel;
  }),
];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  late List<bool> sent;

  setUp(() {
    sent = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      (call) async {
        if (call.method == 'setEligible') sent.add(call.arguments as bool);
        return null;
      },
    );
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      null,
    );
    await h.dispose();
  });

  Future<void> nativeEntersPip() =>
      binding.defaultBinaryMessenger.handlePlatformMessage(
        _channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('modeChanged', true),
        ),
        (_) {},
      );

  Future<ProviderContainer> twoAccountsWithCallOnFirst() async {
    h = AccountHarness(extraOverrides: _overrides());
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    final first = h.host.runtimeFor(_a)!.container;
    first.read(testCallProvider.notifier).state = connectedCall;
    first.read(_eligible.notifier).state = true;
    first.read(pictureInPictureHostProvider);
    await pumpEventQueueTimes();
    return first;
  }

  test('opening another account keeps the call eligible to float', () async {
    final first = await twoAccountsWithCallOnFirst();
    expect(sent, [true]);

    await h.host.switchTo(_b);
    h.host.runtimeFor(_b)!.container.read(pictureInPictureHostProvider);
    await pumpEventQueueTimes();
    await h.host.switchTo(_a);
    await pumpEventQueueTimes();

    expect(sent, isNot(contains(false)));
    expect(first.read(pictureInPictureEligibleProvider), isTrue);
  });

  test('the window entering reaches the account that owns the call', () async {
    final first = await twoAccountsWithCallOnFirst();
    await h.host.switchTo(_b);
    final second = h.host.runtimeFor(_b)!.container;
    second.read(pictureInPictureHostProvider);
    await pumpEventQueueTimes();

    await nativeEntersPip();
    await pumpEventQueueTimes();

    expect(first.read(inPictureInPictureProvider), isTrue);
    expect(second.read(inPictureInPictureProvider), isFalse);
  });

  test('a call that moves hands eligibility to its new owner', () async {
    final first = await twoAccountsWithCallOnFirst();
    await h.host.switchTo(_b);
    final second = h.host.runtimeFor(_b)!.container;
    second.read(pictureInPictureHostProvider);
    await pumpEventQueueTimes();
    expect(sent, [true]);

    first.read(testCallProvider.notifier).state = const VoiceFlags();
    second.read(testCallProvider.notifier).state = connectedCall;
    await pumpEventQueueTimes();

    expect(sent, [true, false]);
  });
}
