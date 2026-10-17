// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message page-size preference: it defaults to the standard 50 the app
/// has always fetched, a choice persists and restores, an unknown stored value
/// degrades to the default, only the default names itself so in the picker, and
/// every option stays at or under the server's 100-row cap.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/message_page_size.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('defaults to the standard page, so it changes nothing on its own', () {
    expect(
      container().read(messagePageSizeControllerProvider),
      MessagePageSize.standard,
    );
    expect(MessagePageSize.standard.rows, 50);
    expect(MessagePageSize.standard.label, contains('default'));
    expect(MessagePageSize.small.label, isNot(contains('default')));
    expect(MessagePageSize.large.label, isNot(contains('default')));
  });

  test('every option is at or under the server MAX_LIMIT of 100', () {
    for (final value in MessagePageSize.values) {
      expect(value.rows, lessThanOrEqualTo(100));
      expect(value.rows, greaterThan(0));
    }
  });

  test('selecting persists, and restore reads it back', () async {
    final c = container();
    await c
        .read(messagePageSizeControllerProvider.notifier)
        .select(MessagePageSize.large);
    expect(
      (await SharedPreferences.getInstance()).getString(messagePageSizeKey),
      'large',
    );

    final c2 = container();
    await c2.read(messagePageSizeControllerProvider.notifier).restore();
    expect(c2.read(messagePageSizeControllerProvider), MessagePageSize.large);
  });

  test('an unknown stored value degrades to the default', () async {
    SharedPreferences.setMockInitialValues({messagePageSizeKey: 'huge'});
    final c = container();
    await c.read(messagePageSizeControllerProvider.notifier).restore();
    expect(c.read(messagePageSizeControllerProvider), MessagePageSize.standard);
  });
}
