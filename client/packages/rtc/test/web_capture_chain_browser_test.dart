// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser where the worklet cannot load: the mic goes out raw and the input
/// gate poll says the chain is not running instead of staying silent. Run with
/// `flutter test --platform chrome`; the VM suites skip it.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/src/web_capture_chain_web.dart';

class _Track implements rtc.MediaStreamTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a worklet that will not load leaves the mic raw and says so', () async {
    final track = _Track();

    final out = await attachWebCaptureChain(track);
    final reading = await invokeWebCaptureChain('getInputGate');

    expect(out, same(track));
    expect(reading, isA<Map<Object?, Object?>>());
    expect((reading! as Map)['strongNoiseSuppression'], false);
  });
}
