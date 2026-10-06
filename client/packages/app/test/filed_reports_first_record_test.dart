// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/filed_reports.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first report in a fresh container keeps the stored history', () async {
    SharedPreferences.setMockInitialValues({
      filedReportsKey('self'): ['old1', 'old2'],
    });
    final session = api.SessionStore(
      tokens: const api.TokenPair(
        userId: 'self',
        accessToken: 'a',
        refreshToken: 'r',
        accessExpiresAt: 0,
      ),
    );
    final container = ProviderContainer(
      overrides: [sessionProvider.overrideWithValue(session)],
    );
    addTearDown(container.dispose);
    await container.read(filedReportsProvider.notifier).record('new');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(filedReportsKey('self')), [
      'new',
      'old1',
      'old2',
    ]);
  });
}
