// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which permission bits a role preview lists per channel: call bits only where
/// a call runs, canvas bits only where a board exists.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/role_preview/widgets/role_preview_summary.dart';
import 'package:slimm_app/src/permissions.dart';

api.RolePreviewChannel _channel(String kind, {bool? canvas, bool? voice}) =>
    api.RolePreviewChannel(
      id: 'c',
      name: 'n',
      kind: kind,
      position: 0,
      permissions: 0,
      restricted: false,
      canvasEnabled: canvas,
      voiceEnabled: voice,
    );

void main() {
  test('a text channel lists chat bits only', () {
    final bits = rolePreviewBits(_channel('text'));
    expect(bits, contains(Perm.manageMessages));
    expect(bits, isNot(contains(Perm.connect)));
    expect(bits, isNot(contains(Perm.useCanvas)));
  });

  test('a voice channel lists call bits, and canvas only while it is on', () {
    final on = rolePreviewBits(_channel('voice', canvas: true, voice: true));
    expect(on, containsAll([Perm.connect, Perm.speak, Perm.useCanvas]));
    final off = rolePreviewBits(_channel('voice', canvas: false, voice: true));
    expect(off, contains(Perm.connect));
    expect(off, isNot(contains(Perm.useCanvas)));
  });

  test('a canvas channel lists voice bits only when it hosts a call', () {
    final quiet = rolePreviewBits(
      _channel('canvas', canvas: true, voice: false),
    );
    expect(quiet, contains(Perm.useCanvas));
    expect(quiet, isNot(contains(Perm.connect)));
    expect(quiet, isNot(contains(Perm.moveMembers)));
    final calling = rolePreviewBits(
      _channel('canvas', canvas: true, voice: true),
    );
    expect(calling, containsAll([Perm.useCanvas, Perm.connect, Perm.speak]));
  });

  test('an older server keeps the old rule', () {
    expect(rolePreviewBits(_channel('voice')), contains(Perm.useCanvas));
    expect(rolePreviewBits(_channel('voice')), contains(Perm.connect));
  });
}
