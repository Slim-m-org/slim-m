// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart' show DropItem;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/web_file_drop_web.dart';
import 'package:web/web.dart' as web;

web.File _file(String name, int size) => web.File(
  [Uint8List.fromList(List.generate(size, (i) => i % 251)).toJS].toJS,
  name,
);

void _dispatchDrop(web.DataTransfer transfer) => web.window.dispatchEvent(
  web.DragEvent(
    'drop',
    web.DragEventInit(
      dataTransfer: transfer,
      cancelable: true,
      clientX: 5,
      clientY: 6,
    ),
  ),
);

void main() {
  test('a large file is read in bounded slices', () async {
    final size = kDropReadChunk * 2 + 10;
    final sizes = [
      await for (final c in blobChunks(_file('big.bin', size))) c.length,
    ];
    expect(sizes, [kDropReadChunk, kDropReadChunk, 10]);
  });

  test('a slice honours start and end', () async {
    final bytes = [
      await for (final c in blobChunks(_file('a.bin', 100), 10, 20)) ...c,
    ];
    expect(bytes, List.generate(10, (i) => (10 + i) % 251));
  });

  test('a dropped file reads back whole and resumes from an offset', () async {
    final item = WebDropFile(_file('a.bin', 50));
    expect((await item.readAsBytes()).length, 50);
    final tail = [await for (final c in item.openRead(40)) ...c];
    expect(tail.length, 10);
  });

  testWidgets('a drag that carries strings beside the file still drops it', (
    tester,
  ) async {
    List<DropItem>? dropped;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: WebFileDropTarget(
          enable: true,
          onEntered: (_) {},
          onUpdated: (_) {},
          onExited: () {},
          onDone: (files, global, local) => dropped = files,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final transfer = web.DataTransfer()
      ..items.add('https://example.test/cat.png'.toJS, 'text/uri-list')
      ..items.add('<img src="cat.png">'.toJS, 'text/html')
      ..items.add(_file('cat.png', 8));

    _dispatchDrop(transfer);

    expect(dropped!.map((f) => f.name), ['cat.png']);
  });

  testWidgets('a drag of only text is left to the browser', (tester) async {
    var done = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: WebFileDropTarget(
          enable: true,
          onEntered: (_) {},
          onUpdated: (_) {},
          onExited: () {},
          onDone: (files, global, local) => done = true,
          child: const SizedBox.expand(),
        ),
      ),
    );
    _dispatchDrop(
      web.DataTransfer()..items.add('just text'.toJS, 'text/plain'),
    );
    expect(done, isFalse);
  });
}
