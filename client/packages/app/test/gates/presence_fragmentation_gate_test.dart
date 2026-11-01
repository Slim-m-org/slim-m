// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One avatar and one presence indicator, enforced.
///
/// The owner: "user statuses and pfps are a mess ... a single component for
/// status and pfp handling throughout the app". They were a mess because any
/// file could draw its own dot or assemble its own avatar, so each surface
/// answered "is this person online" its own way: the footer read the caller's
/// unreadable choice and said "unknown" while the member list beside it showed
/// the same person online. This fails when a file outside the shared
/// components does either again.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/presence_gate.dart';

void main() {
  test('no file outside the shared components draws presence or an avatar', () {
    final root = Directory('..');
    expect(
      File('${root.path}/app/pubspec.yaml').existsSync(),
      isTrue,
      reason: 'run this from the app package root',
    );
    expect(presenceGateViolations(root), isEmpty);
  });

  test('the gate catches code shaped like what it replaced', () {
    final fixture = Directory.systemTemp.createTempSync('presence-gate');
    addTearDown(() => fixture.deleteSync(recursive: true));
    void put(String path, String source) {
      File('${fixture.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(source);
    }

    put('app/lib/src/widgets/a_row.dart', '''
Widget build() => AppAvatar(name: 'x', status: AppPresence.offline);
''');
    put('app/lib/src/widgets/a_dot.dart', '''
Widget build() => Row(children: [AppStatusDot(status: s), Text(w)]);
''');
    put('app/lib/src/widgets/a_map.dart', '''
final p = ref.watch(presenceControllerProvider)[id];
''');
    put('app/lib/src/widgets/a_size.dart', '''
Widget build() => UserAvatar(name: n, userId: i, size: 26);
''');
    put('app/lib/src/widgets/a_known.dart', '''
Widget build() => UserAvatar.known(name: n, userId: i, avatarUpdatedAt: v, size: 20);
''');
    put('app/lib/src/widgets/fine.dart', '''
// AppAvatar( and AppStatusDot( in a comment, and a string: 'AppAvatar('
Widget build() => UserAvatar(name: n, userId: i, size: AppAvatarSize.s28);
''');

    final violations = presenceGateViolations(fixture);
    final files = violations.map((v) => v.split(':').first).toSet();
    expect(files, {
      'app/lib/src/widgets/a_row.dart',
      'app/lib/src/widgets/a_dot.dart',
      'app/lib/src/widgets/a_map.dart',
      'app/lib/src/widgets/a_size.dart',
      'app/lib/src/widgets/a_known.dart',
    });
  });
}
