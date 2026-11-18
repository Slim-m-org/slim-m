// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A clip file too large to read still says how large it is, and an empty one
/// is refused before it is sent, as attachments and emoji already are.
library;

import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/screens/admin/soundboard_intake.dart';
import 'package:slimm_app/src/format.dart';

import '../../support/async_wait.dart';
import 'soundboard_harness.dart';

const _huge = 3 * 1024 * 1024;

/// A dropped file over the limit whose bytes must never be read.
class _UnreadDrop extends DropItemFile {
  _UnreadDrop(super.path) : super(name: path);

  @override
  Future<int> length() async => _huge;

  @override
  Future<Uint8List> readAsBytes() => throw StateError('read whole');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an oversized file names its own size', () async {
    final pick = await readDroppedSoundClip([_UnreadDrop('long.mp3')]);
    expect(pick!.size, _huge);
    expect(soundClipFileProblem(pick), contains(formatByteSize(_huge)));
  });

  test('an empty file is refused', () async {
    final pick = await readDroppedSoundClip([
      DropItemFile.fromData(Uint8List(0), name: 'blank.mp3', path: 'blank.mp3'),
    ]);
    expect(soundClipFileProblem(pick!), 'That file is empty.');
  });

  testWidgets('the sheet shows an oversized file at its real size', (
    tester,
  ) async {
    final wire = SoundboardWire();
    await pumpSoundboard(
      tester,
      wire,
      picker: () => readDroppedSoundClip([_UnreadDrop('long.mp3')]),
    );
    await openCreateClip(tester);

    expect(find.text(formatByteSize(_huge)), findsOneWidget);
    expect(find.text('0 B'), findsNothing);
    await tester.tap(sheetCreateButton);
    await pumpFrames(tester);
    expect(wire.writes, isEmpty);
  });
}
