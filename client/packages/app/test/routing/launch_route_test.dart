// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which arrival counts as the page load: only the first, only on the
/// channel the page opened on, and never once the app has shown elsewhere.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/routing/launch_route.dart';

void main() {
  test('the first arrival on the page load channel is the page load', () {
    final launch = LaunchRoute('/channels/voice-1');
    expect(launch.takeArrival('voice-1'), isTrue);
    expect(launch.takeArrival('voice-1'), isFalse, reason: 'a later click');
  });

  test('a native launch never matches', () {
    expect(LaunchRoute('/').takeArrival('voice-1'), isFalse);
  });

  test('an arrival elsewhere first uses it up', () {
    final launch = LaunchRoute('/channels/voice-1');
    expect(launch.takeArrival('voice-2'), isFalse);
    expect(launch.takeArrival('voice-1'), isFalse);
  });

  test('showing another page first uses it up', () {
    final launch = LaunchRoute('/channels/voice-1')
      ..showed('/channels/voice-1')
      ..showed('/sign-in');
    expect(launch.takeArrival('voice-1'), isFalse);
  });

  test('the chat view of the same channel still counts', () {
    expect(
      LaunchRoute('/channels/voice-1?chat=1').takeArrival('voice-1'),
      isTrue,
    );
  });
}
