// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_source_sheet.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  const screen = ScreenShareSource(id: '0', name: 'Screen 1');
  const window = ScreenShareSource(id: '42', name: 'Game', isWindow: true);

  test(
    'Windows with window sources says which fullscreen cannot be captured',
    () {
      final caption = screenSourceCaption([screen, window], windows: true);
      expect(caption, contains('exclusive fullscreen'));
      expect(caption, contains('share the screen instead'));
    },
  );

  test('a screens-only list or another platform keeps the plain caption', () {
    const plain = 'Everyone in the call will see it until you stop sharing.';
    expect(screenSourceCaption([screen], windows: true), plain);
    expect(screenSourceCaption([screen, window], windows: false), plain);
  });
}
