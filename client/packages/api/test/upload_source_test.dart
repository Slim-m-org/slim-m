// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Cutting a part out of one big chunk must not copy what is left of it.
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:slimm_api/api.dart';

void main() {
  test('parts cut from one large chunk are views, not copies', () async {
    final whole = Uint8List.fromList(List.generate(12, (i) => i));
    final source = UploadSource(open: () => Stream.value(whole));

    final first = [
      await for (final c in source.part(0, 4)) c,
    ].single;
    final second = [
      await for (final c in source.part(4, 8)) c,
    ].single;

    expect(first, [0, 1, 2, 3]);
    expect(second, [4, 5, 6, 7, 8, 9, 10, 11]);
    expect((first as Uint8List).offsetInBytes, 0);
    expect((second as Uint8List).offsetInBytes, 4);
  });

  test('a resume without openAt skips to the offset', () async {
    final source = UploadSource(
      open: () => Stream.fromIterable([
        Uint8List.fromList([0, 1, 2]),
        Uint8List.fromList([3, 4, 5]),
      ]),
    );
    final bytes = [
      await for (final c in source.part(4, 2)) ...c,
    ];
    expect(bytes, [4, 5]);
  });
}
