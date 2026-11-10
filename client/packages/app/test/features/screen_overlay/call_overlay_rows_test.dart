// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the call panel lists per person and how faintly it is dressed.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/call_overlay_avatar.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/call_overlay_panel.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _person(
  String id, {
  String? name,
  bool local = false,
  bool speaking = false,
  bool muted = false,
  bool deafened = false,
}) => VoiceParticipant(
  identity: id,
  name: name ?? id,
  isSpeaking: speaking,
  isMuted: muted,
  isLocal: local,
  isScreenSharing: false,
  isDeafened: deafened,
);

void main() {
  test('you come first, then the call in its own order', () {
    final rows = callOverlayRows([
      _person('a'),
      _person('me', local: true),
      _person('b'),
    ]).rows;
    expect(rows.map((r) => r.id), ['me', 'a', 'b']);
    expect(rows.first.name, 'me (you)');
  });

  test('a row carries the user id its picture is cached under', () {
    final rows = callOverlayRows([_person('u-1', name: 'Riley')]).rows;
    expect((rows.single.id, rows.single.name), ('u-1', 'Riley'));
  });

  test('a talking person lights up, a muted or deafened one does not', () {
    final rows = callOverlayRows([
      _person('a', speaking: true),
      _person('b', speaking: true, muted: true),
      _person('c', speaking: true, deafened: true),
    ]).rows;
    expect(rows.map((r) => r.speaking), [true, false, false]);
    expect(rows.map((r) => (r.muted, r.deafened)), [
      (false, false),
      (true, false),
      (false, true),
    ]);
  });

  test('each row gets its baked picture by user id, or none', () {
    final png = Uint8List.fromList([7]);
    final rows = callOverlayRows(
      [_person('a'), _person('b')],
      avatars: {'a': OverlayAvatar(key: 'k', png: png)},
    ).rows;
    expect((rows[0].avatarKey, rows[0].avatar), ('k', png));
    expect((rows[1].avatarKey, rows[1].avatar), (null, null));
  });

  test('past eight rows the rest are counted, and only eight are shown', () {
    final people = [for (var i = 0; i < 11; i++) _person('p$i')];
    expect(callOverlayShown(people), hasLength(8));
    expect(callOverlayRows(people).more, 3);
    expect(callOverlayRows(people.take(8).toList()).more, 0);
  });

  test('the panel is faint: a mostly see-through surface and text at 90%', () {
    final panel = callOverlayPanel(
      [_person('a')],
      monitor: 0,
      corner: OverlayCorner.topLeft,
    );
    expect(panel.surface.a, closeTo(0.6, 0.01));
    expect(panel.text.a, closeTo(0.9, 0.01));
    expect(panel.textMuted.a, closeTo(0.9, 0.01));
  });
}
