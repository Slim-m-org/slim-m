// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One handler per channel, however many listeners, and none once all leave.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/method_channel_hub.dart';

const _name = 'test/method_channel_hub';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<ByteData?> nativeCall() async {
    ByteData? reply;
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      _name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('ping')),
      (data) => reply = data,
    );
    return reply;
  }

  test('every listener hears a call and the handler goes with the last',
      () async {
    final hub = MethodChannelHub.of(const MethodChannel(_name));
    final first = <String>[];
    final second = <String>[];
    final a = hub.calls.listen((c) => first.add(c.method));
    final b = hub.calls.listen((c) => second.add(c.method));

    expect(await nativeCall(), isNotNull);
    expect([
      first,
      second
    ], [
      ['ping'],
      ['ping'],
    ]);

    await a.cancel();
    expect(await nativeCall(), isNotNull, reason: 'one listener remains');
    expect(second, ['ping', 'ping']);

    await b.cancel();
    expect(await nativeCall(), isNull, reason: 'nobody listens, no handler');
  });
}
