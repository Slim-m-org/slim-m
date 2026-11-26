// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('ThreadParent reads the parent created_at, null from an older server',
      () {
    expect(
      ThreadParent.fromJson({
        'parent_channel_id': 'c',
        'parent_created_at': 1700000000123,
      }).parentCreatedAt,
      1700000000123,
    );
    expect(
      ThreadParent.fromJson({'parent_channel_id': 'c'}).parentCreatedAt,
      isNull,
    );
  });
}
