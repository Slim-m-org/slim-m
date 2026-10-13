// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a drop onto a one-picture surface amounts to, and the overlay it shows
/// at any target height.
library;

import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/app_drop_zone.dart';
import 'package:slimm_app/src/widgets/image_drop_zone.dart';
import 'package:slimm_design_system/design_system.dart';

DropItem _file(String name) =>
    DropItemFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: name,
      path: '/tmp/drops/$name',
    );

void main() {
  test(
    'one still picture is read, whatever the case of its extension',
    () async {
      for (final name in ['a.png', 'b.JPG', 'c.jpeg', 'd.webp']) {
        final drop = await readDroppedImage([_file(name)]);
        expect(drop, isA<DroppedImage>(), reason: name);
        expect((drop as DroppedImage).bytes, [1, 2, 3]);
        expect(drop.name, name);
      }
    },
  );

  test('anything but one still picture is refused with one sentence', () async {
    final refused = [
      [_file('party.gif')],
      [_file('clip.mp4')],
      [_file('notes.pdf')],
      [_file('noextension')],
      [_file('a.png'), _file('b.png')],
      <DropItem>[],
      [DropItemDirectory('/tmp/pictures', const [])],
    ];
    for (final items in refused) {
      final drop = await readDroppedImage(items);
      expect(drop, isA<RefusedDrop>(), reason: '${items.map((i) => i.name)}');
      expect(
        (drop as RefusedDrop).message,
        'Drop one PNG, JPEG or WebP picture.',
      );
    }
  });

  for (final (height, stacked) in [(32.0, false), (200.0, true)]) {
    testWidgets('the overlay fits a ${height.toInt()}px target', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: height,
                child: const AppDropOverlay(
                  label: 'Drop to set the banner',
                  icon: AppIcons.image,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final icon = tester.getCenter(find.byType(Icon));
      final label = tester.getCenter(find.text('Drop to set the banner'));
      if (stacked) {
        expect(icon.dy, lessThan(label.dy));
      } else {
        expect(icon.dx, lessThan(label.dx));
        expect((icon.dy - label.dy).abs(), lessThan(2));
      }
    });
  }
}
