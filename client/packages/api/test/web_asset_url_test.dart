// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:test/test.dart';
import 'package:slimm_api/api.dart';

void main() {
  test('a lazily fetched asset carries the build id', () {
    expect(
      versionedWebAssetUrl('capture_chain.wasm', build: 'abc123'),
      'capture_chain.wasm?v=abc123',
    );
  });

  test('a build without an id leaves the path alone', () {
    expect(versionedWebAssetUrl('sqlite3.wasm', build: ''), 'sqlite3.wasm');
  });
}
