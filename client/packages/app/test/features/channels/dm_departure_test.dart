// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM row whose other people have left the Space reads as such.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_data/data.dart';

import 'group_dm_harness.dart';

class _Server extends GroupDmServer {
  _Server({required this.profileExists});

  final bool profileExists;

  @override
  Future<http.Response> handle(http.Request request) {
    if (request.url.path == '/users') {
      return Future.value(
        jsonResponse([if (profileExists) personJson('u99', 'Gone')]),
      );
    }
    return super.handle(request);
  }
}

Channel _pair(String peer) => Channel(
  id: 'p1',
  name: 'Gone',
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: peer,
);

Future<void> _pump(WidgetTester tester, GroupDmServer server, Channel c) async {
  final container = groupDmContainer(server);
  addTearDown(container.dispose);
  await pumpGroupDm(tester, container, DmRow(channel: c, selected: false));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a peer missing from the roster reads as left the Space', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: true), _pair('u99'));
    expect(find.text('Left the Space'), findsOneWidget);
  });

  testWidgets('a peer whose account is gone reads as a deleted user', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: false), _pair('u99'));
    expect(find.text('Deleted user'), findsOneWidget);
  });

  testWidgets('a peer still in the roster looks ordinary', (tester) async {
    await _pump(tester, _Server(profileExists: true), _pair('u1'));
    expect(find.text('Left the Space'), findsNothing);
    expect(find.text('Deleted user'), findsNothing);
  });

  testWidgets('a group is marked only when everyone else has left', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: true), _group('self,u1,u99'));
    expect(find.text('Left the Space'), findsNothing);
  });

  testWidgets('a group everyone else has left is marked', (tester) async {
    await _pump(tester, _Server(profileExists: true), _group('self,u98,u99'));
    expect(find.text('Left the Space'), findsOneWidget);
  });
}

Channel _group(String members) => Channel(
  id: 'g9',
  name: 'Group',
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmMemberIds: members,
);
