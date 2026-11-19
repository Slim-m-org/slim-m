// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Linux portal names the shared monitor by its position at the start of
/// the share; after the layout changes only the monitor's name still finds it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/portal_screen.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show PortalMonitor;

OverlayMonitor _at(int x, String name, {int width = 1920}) => OverlayMonitor(
  x: x,
  y: 0,
  width: width,
  height: 1080,
  primary: false,
  name: name,
);

void main() {
  PortalMonitor? reported;
  late PortalScreen screen;

  setUp(() {
    reported = (x: 1920, y: 0, width: 1920, height: 1080);
    screen = PortalScreen(() async => reported);
  });

  test('the reported position settles identical monitors', () async {
    expect(await screen.find([_at(0, 'DP-5'), _at(1920, 'DP-6')]), 1);
  });

  test(
    'a position no monitor has finds nothing, for the shape to decide',
    () async {
      reported = (x: 5, y: 5, width: 1920, height: 1080);
      expect(await screen.find([_at(0, 'DP-5'), _at(1920, 'DP-6')]), isNull);
    },
  );

  test('after a change the name finds it, not the old position', () async {
    final before = [_at(0, 'DP-5'), _at(1920, 'DP-6')];
    expect(await screen.find(before), 1);

    await screen.layoutChanging(before);

    expect(await screen.find([_at(0, 'DP-6'), _at(1920, 'DP-5')]), 0);
  });

  test('a change before the overlay ever opened pins the name first', () async {
    final before = [_at(0, 'DP-5'), _at(1920, 'DP-6')];

    await screen.layoutChanging(before);

    expect(await screen.find([_at(1536, 'DP-6'), _at(0, 'DP-5')]), 0);
  });

  test('a name the new layout lacks, or has twice, finds nothing', () async {
    final before = [_at(0, 'DP-5'), _at(1920, 'DP-6')];
    await screen.layoutChanging(before);

    expect(await screen.find([_at(0, 'DP-5'), _at(1920, 'HDMI-A-1')]), isNull);
    expect(await screen.find([_at(0, 'DP-6'), _at(1920, 'DP-6')]), isNull);
  });

  test('a new share starts over with its own position', () async {
    await screen.layoutChanging([_at(0, 'DP-5'), _at(1920, 'DP-6')]);
    screen.forget();

    expect(await screen.find([_at(0, 'DP-6'), _at(1920, 'DP-5')]), 1);
  });

  test('a different answer from the portal is a different share', () async {
    await screen.layoutChanging([_at(0, 'DP-5'), _at(1920, 'DP-6')]);
    reported = (x: 0, y: 0, width: 1920, height: 1080);

    expect(await screen.find([_at(0, 'DP-6'), _at(1920, 'DP-5')]), 0);
  });

  test('no answer from the portal finds nothing', () async {
    reported = null;
    expect(await screen.find([_at(0, 'DP-5')]), isNull);
  });
}
