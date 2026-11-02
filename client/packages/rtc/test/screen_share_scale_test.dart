// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A desktop share's layers scale from the frames captured, not from the declared size.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/src/screen_share_scale.dart';

void main() {
  test('every layer keeps its ratio to the top one after scaling', () {
    final encodings = [
      rtc.RTCRtpEncoding(rid: 'q', scaleResolutionDownBy: 2),
      rtc.RTCRtpEncoding(rid: 'f', scaleResolutionDownBy: 1),
    ];
    scaleEncodings(encodings, 2);
    expect(encodings.map((e) => e.scaleResolutionDownBy), [4.0, 2.0]);
  });

  test('a missing scale counts as one', () {
    final encodings = [
      rtc.RTCRtpEncoding(rid: 'f')..scaleResolutionDownBy = null
    ];
    scaleEncodings(encodings, 1.5);
    expect(encodings.single.scaleResolutionDownBy, 1.5);
  });
}
