// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel address the signed-in user cannot resolve (hidden from them, or
/// never there) says so and offers no composer. It used to fall through to
/// the conversation screen with a blank header and the DM copy.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/channel_not_found.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_data/data.dart';

import 'home_shell_harness.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _pump(
  WidgetTester tester,
  String location, {
  bool synced = true,
}) async {
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [initialSyncCompleteProvider.overrideWith((ref) => synced)],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await pumpAtWidth(tester, s.container, 1400, location: location);
  return s;
}

void main() {
  testWidgets('an unknown channel id says not found and has no composer', (
    tester,
  ) async {
    final s = await _pump(tester, '/channels/hidden');

    expect(find.byType(ChannelNotFound), findsOneWidget);
    expect(find.textContaining('not found'), findsOneWidget);
    expect(find.byType(Composer), findsNothing);
    expect(find.textContaining('just between the two of you'), findsNothing);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('a channel the store holds still opens with its composer', (
    tester,
  ) async {
    final s = await _pump(tester, '/channels/c1');

    expect(find.byType(ChannelNotFound), findsNothing);
    expect(find.byType(Composer), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('before the first sync an unknown id is not yet called gone', (
    tester,
  ) async {
    final s = await _pump(tester, '/channels/hidden', synced: false);

    expect(find.byType(ChannelNotFound), findsNothing);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('the way out leads back to the channel list', (tester) async {
    final s = await _pump(tester, '/channels/hidden');

    await tester.tap(find.text('Back to channels'));
    await tester.pumpAndSettle();

    expect(find.byType(ChannelNotFound), findsNothing);
    expect(find.text('conversation'), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });
}
