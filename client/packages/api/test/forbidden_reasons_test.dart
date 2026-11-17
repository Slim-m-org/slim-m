// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reasoned 403 keeps its code, and a timeout keeps when it lifts and why.
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  Future<void> expectMapped(String body, Matcher matcher) async {
    final api = SlimmApi(
      baseUrl: Uri.parse('https://slim.example'),
      httpClient: MockClient((_) async => http.Response(body, 403)),
    );
    await expectLater(api.version, throwsA(matcher));
  }

  test('a timed-out 403 carries when it lifts and why', () async {
    await expectMapped(
      '{"error":"you are timed out","code":"timed_out",'
      '"timed_out_until":1700000000000,"timeout_reason":"cool off"}',
      isA<ForbiddenException>()
          .having((e) => e.code, 'code', ForbiddenException.timedOutCode)
          .having((e) => e.timedOutUntil, 'timedOutUntil', 1700000000000)
          .having((e) => e.timeoutReason, 'timeoutReason', 'cool off'),
    );
  });

  test('a bare 403 carries no timeout', () async {
    await expectMapped(
      '{"error":"insufficient permissions"}',
      isA<ForbiddenException>()
          .having((e) => e.code, 'code', isNull)
          .having((e) => e.timedOutUntil, 'timedOutUntil', isNull),
    );
  });
}
