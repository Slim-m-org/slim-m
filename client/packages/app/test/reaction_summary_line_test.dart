// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/reaction_users_list.dart';

void main() {
  test('fewer loaded names than the count never indexes past the list', () {
    expect(reactionSummaryLine(['Ada'], 2), 'Ada and 1 other');
    expect(reactionSummaryLine(['Ada'], 3), 'Ada and 2 others');
    expect(reactionSummaryLine(['Ada'], 9), 'Ada and 8 others');
  });
}
