// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tapping a message link inside a message.
///
/// `deep_links_test.dart` covers a link arriving from outside the app, and
/// `message_text_test.dart` covers an ordinary URL getting a recognizer.
/// Nothing rendered a `MessageBody` containing a message link and tapped it,
/// so `_openMessage` - the parse, the same-server check, the refusal and the
/// jump - had never executed under a test at all.
///
/// The router is the cost here: `_openMessage` reaches `GoRouter.of(context)`
/// and `selectedChannelId(context)`, so a bare `MaterialApp` cannot drive it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/message_link.dart';
import 'package:slimm_app/src/features/modules/providers/code_block_runner.dart';
import 'package:slimm_app/src/providers/message_jump.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

const _here = 'https://slim.example';
const _elsewhere = 'https://other.example';

/// Records the jump instead of running it: the real controller pages history
/// out of a drift store, which is a whole fixture this test has no use for.
class _RecordingJump extends MessageJumpController {
  _RecordingJump(super.ref);

  final jumps = <(String channelId, String messageId)>[];

  @override
  Future<void> jumpTo(String channelId, String messageId) async {
    jumps.add((channelId, messageId));
  }
}

class _Harness {
  _Harness(this.router, this.jump);
  final GoRouter router;
  final _RecordingJump jump;

  String get location =>
      router.routerDelegate.currentConfiguration.uri.toString();
}

Future<_Harness> _pump(WidgetTester tester, String content) async {
  final router = GoRouter(
    initialLocation: Routes.channel('c-here'),
    routes: [
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) => Scaffold(
          body: MessageBody(content: content, knownUsernames: const {}),
        ),
      ),
    ],
  );

  final container = ProviderContainer(
    overrides: [
      codeBlockRunnerProvider.overrideWith((ref) async => const []),
      serverUrlProvider.overrideWithValue(Uri.parse(_here)),
      messageJumpProvider.overrideWith(_RecordingJump.new),
    ],
  );
  addTearDown(container.dispose);
  // Read eagerly: an override's closure is lazy, and the tap needs this.
  final jump = container.read(messageJumpProvider.notifier) as _RecordingJump;

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(router, jump);
}

/// The label a message link renders as, rather than the raw `slimm://` URL.
const _linkLabel = 'message link';

/// Taps the message link's own span by invoking its recognizer.
///
/// Not a coordinate tap: the link is one span inside a paragraph, and hit
/// testing a substring would assert about text layout rather than about what
/// the tap does. The recognizer is the wiring under test.
void _tapLink(WidgetTester tester) {
  TapGestureRecognizer? found;
  for (final element in find.byType(RichText).evaluate()) {
    final span = (element.widget as RichText).text as TextSpan;
    span.visitChildren((child) {
      if (child is TextSpan &&
          child.text == _linkLabel &&
          child.recognizer is TapGestureRecognizer) {
        found = child.recognizer! as TapGestureRecognizer;
        return false;
      }
      return true;
    });
    if (found != null) break;
  }
  expect(found, isNotNull, reason: 'the link has to render as its own span');
  found!.onTap!();
}

void main() {
  // Fails: a no-op _openMessage; inverting messageLinkIsHere.
  testWidgets('a link to this server jumps to the message', (tester) async {
    final h = await _pump(
      tester,
      'see ${buildMessageLink(server: Uri.parse(_here), channelId: 'c-target', messageId: 'm-9')} for that',
    );

    _tapLink(tester);
    await tester.pumpAndSettle();

    expect(h.location, Routes.channel('c-target', openChat: true));
    expect(h.jump.jumps, [
      ('c-target', 'm-9'),
    ], reason: 'the jump names the channel and message the link pointed at');
  });

  // Fails: inverting messageLinkIsHere; deleting the showAppSnackbar call.
  testWidgets('a link to another server is refused, and says so', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      'see ${buildMessageLink(server: Uri.parse(_elsewhere), channelId: 'c-target', messageId: 'm-9')} for that',
    );

    _tapLink(tester);
    await tester.pumpAndSettle();

    expect(find.text('That link is for a different server.'), findsOneWidget);
    expect(
      h.location,
      Routes.channel('c-here'),
      reason: 'one deployment is one community; a tapped link cannot switch',
    );
    expect(h.jump.jumps, isEmpty);
  });
}
