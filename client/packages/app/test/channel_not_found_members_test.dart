// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel the viewer cannot resolve owns the whole content area: no member
/// pane, no members control and no members request, which would list people
/// from a channel the viewer has no access to.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/channel_not_found.dart';
import 'package:slimm_app/src/widgets/member_pane.dart';
import 'package:slimm_data/data.dart';

import 'home_shell_harness.dart';

Future<({List<String> paths, ProviderContainer container, SlimmDatabase db})>
_pump(WidgetTester tester, String location, double width) async {
  final paths = <String>[];
  final quiet = quietClient();
  final s = setup(
    httpClient: MockClient((request) async {
      paths.add(request.url.toString());
      // Forwarded by URL: a Request cannot be sent twice.
      return quiet.get(request.url);
    }),
    signedIn: true,
    extraOverrides: [initialSyncCompleteProvider.overrideWith((ref) => true)],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await pumpAtWidth(tester, s.container, width, location: location);
  // The pane asks whether an unlisted id is a thread before it says not found.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
  return (paths: paths, container: s.container, db: s.db);
}

/// The deployment-wide roster other surfaces read is fine; a request scoped
/// to the unresolved channel is the one that must not happen.
Iterable<String> _channelMembersRequests(List<String> urls) =>
    urls.where((u) => u.contains('/members') && u.contains('channel='));

void main() {
  for (final width in [1400.0, 400.0]) {
    testWidgets('an unresolved channel shows no member pane or members '
        'request at ${width.toInt()}px', (tester) async {
      final semantics = tester.ensureSemantics();
      final r = await _pump(tester, '/channels/hidden', width);

      expect(find.byType(ChannelNotFound), findsOneWidget);
      expect(find.byType(AppMemberPane), findsNothing);
      expect(find.bySemanticsLabel('Show members'), findsNothing);
      expect(_channelMembersRequests(r.paths), isEmpty);

      semantics.dispose();
      await teardown(tester, r.container, r.db);
    });
  }

  testWidgets('a resolved channel at phone width still offers its members', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final r = await _pump(tester, '/channels/c1', 400);

    expect(find.byType(ChannelNotFound), findsNothing);
    expect(find.bySemanticsLabel('Show members'), findsOneWidget);

    semantics.dispose();
    await teardown(tester, r.container, r.db);
  });
}
