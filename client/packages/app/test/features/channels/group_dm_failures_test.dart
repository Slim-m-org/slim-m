// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Group DM requests that fail or are repeated: the reason a refusal gives,
/// and the id a retry after a lost reply carries.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'group_dm_harness.dart';

const _blockedReason =
    'a block between two of these people stops them sharing a group';

const _unreachable =
    'Could not start the group: the server could not be reached. '
    'Nothing was changed.';

final _start = find.text('Start group with 3 people');

/// Taps [target] and waits until the server has seen one more write.
Future<void> _tapWrite(
  WidgetTester tester,
  GroupDmServer server,
  Finder target,
) async {
  final before = server.writes;
  await tester.tap(target);
  await waitUntil(tester, () => server.writes > before);
}

List<String> _createdIds(GroupDmServer server) => [
  for (final r in server.requests)
    if (r.startsWith('POST /dms/groups '))
      (jsonDecode(r.substring('POST /dms/groups '.length))
              as Map<String, dynamic>)['id']
          as String,
];

void main() {
  group('the new group sheet', () {
    const open = openNewGroupSheet;

    testWidgets('a block refusal is explained and the sheet stays open', (
      tester,
    ) async {
      final server = await open(tester);
      server.failNext = jsonResponse({'error': _blockedReason}, 403);
      await tester.tap(personTile('u1'));
      await tester.tap(personTile('u2'));
      await tester.pump();
      await _tapWrite(tester, server, _start);

      expect(
        find.text(
          'Could not start the group. A block between two of these '
          'people stops them sharing a group.',
        ),
        findsOneWidget,
      );
      expect(_start, findsOneWidget, reason: 'the sheet stays open to retry');
    });

    testWidgets('a refusal that is not a block does not blame one', (
      tester,
    ) async {
      final server = await open(tester);
      server.failNext = jsonResponse({'error': 'accept the rules first'}, 403);
      await tester.tap(personTile('u1'));
      await tester.tap(personTile('u2'));
      await tester.pump();
      await _tapWrite(tester, server, _start);

      expect(
        find.text('Could not start the group. Accept the rules first.'),
        findsOneWidget,
      );
      expect(find.textContaining('block'), findsNothing);
    });

    testWidgets('a retry after a lost reply asks for the same group', (
      tester,
    ) async {
      final server = await open(tester);
      server.dropNext = true;
      await tester.tap(personTile('u1'));
      await tester.tap(personTile('u2'));
      await tester.pump();
      await _tapWrite(tester, server, _start);
      expect(find.text(_unreachable), findsOneWidget);

      await _tapWrite(tester, server, _start);

      final ids = _createdIds(server);
      expect(ids, hasLength(2));
      expect(ids[1], ids[0], reason: 'the server replays the group it made');
      expect(find.text('open:g1'), findsOneWidget);
    });

    testWidgets('picking someone else after a failure is a new group', (
      tester,
    ) async {
      final server = await open(tester);
      server.dropNext = true;
      await tester.tap(personTile('u1'));
      await tester.tap(personTile('u2'));
      await tester.pump();
      await _tapWrite(tester, server, _start);

      await tester.tap(personTile('u2'));
      await tester.tap(personTile('u3'));
      await tester.pump();
      await _tapWrite(tester, server, _start);

      final ids = _createdIds(server);
      expect(ids, hasLength(2));
      expect(
        ids[1],
        isNot(ids[0]),
        reason: 'a replayed id returns the first group whoever is picked now',
      );
    });

    testWidgets('renaming after a failure is a new group', (tester) async {
      final server = await open(tester);
      server.dropNext = true;
      await tester.tap(personTile('u1'));
      await tester.tap(personTile('u2'));
      await tester.pump();
      await _tapWrite(tester, server, _start);

      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is AppInput && w.placeholder == 'Group name (optional)',
        ),
        'trip',
      );
      await tester.pump();
      await _tapWrite(tester, server, _start);

      final ids = _createdIds(server);
      expect(ids, hasLength(2));
      expect(ids[1], isNot(ids[0]));
    });
  });

  group('the members sheet', () {
    const open = openMembersSheet;

    testWidgets('a refused add says a block is why', (tester) async {
      final server = await open(tester);
      server.failNext = jsonResponse({'error': _blockedReason}, 403);
      await tester.ensureVisible(personTile('u3'));
      await _tapWrite(tester, server, personTile('u3'));

      expect(
        find.text(
          'Could not add them to the group. A block between two of these people stops '
          'them sharing a group.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a refused add that is not a block does not blame one', (
      tester,
    ) async {
      final server = await open(tester);
      server.failNext = jsonResponse({
        'error': 'you have been removed from this server',
      }, 403);
      await tester.ensureVisible(personTile('u3'));
      await _tapWrite(tester, server, personTile('u3'));

      expect(find.textContaining('removed from this server'), findsOneWidget);
      expect(find.textContaining('block'), findsNothing);
    });
  });
}
