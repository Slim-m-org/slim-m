// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two holds on one channel keep landscape allowed until both are released.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/phone_landscape.dart';
import 'package:slimm_platform/platform.dart';

class _FakeOrientation extends OrientationChannel {
  _FakeOrientation() : super(channel: const MethodChannel('test/orientation'));

  final calls = <bool>[];

  @override
  Future<bool> allowLandscape(bool allowed) async {
    calls.add(allowed);
    return true;
  }
}

void main() {
  test(
    'overlapping holds unlock portrait only when the last is released',
    () async {
      final channel = _FakeOrientation();
      final locked = StateController<bool>(false);
      final first = PhoneLandscapeHold(channel, locked);
      final second = PhoneLandscapeHold(channel, locked);

      await first.enter();
      await second.enter();
      first.release();
      expect(channel.calls, isNot(contains(false)));
      expect(second.held, isTrue);

      second.release();
      expect(channel.calls.last, isFalse);
      expect(channel.calls.where((c) => !c), hasLength(1));
    },
  );

  test('a hold released twice counts once', () async {
    final channel = _FakeOrientation();
    final locked = StateController<bool>(false);
    final first = PhoneLandscapeHold(channel, locked);
    final second = PhoneLandscapeHold(channel, locked);
    await first.enter();
    await second.enter();
    first.release();
    first.release();
    expect(channel.calls, isNot(contains(false)));
  });
}
