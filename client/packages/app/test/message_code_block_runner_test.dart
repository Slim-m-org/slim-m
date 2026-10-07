// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Run affordance on a fenced code block and its inline output, per
/// docs/decisions/0021-modules-and-the-dock.md's module-agnostic principle:
/// [MessageBody] itself never names a module, only whatever
/// `codeBlockRunnerProvider` hands back.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/code_block_runner.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<api.CodeBlockRunner> runners,
  http.Response Function(http.Request)? onRunRequest,
  String? messageId,
  Stream<api.ServerEvent>? events,
  String language = 'js',
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      if (events != null) liveEventsProvider.overrideWithValue(events),
      codeBlockRunnerProvider.overrideWith((ref) async => runners),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (onRunRequest != null) return onRunRequest(request);
            return http.Response('', 404);
          }),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: MessageBody(
            content: '```$language\nconsole.log(1)\n```',
            knownUsernames: const {},
            messageId: messageId,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  testWidgets('no runner available means no Run affordance at all', (
    tester,
  ) async {
    await _pump(tester, runners: const []);

    expect(find.bySemanticsLabel('Run with code-exec'), findsNothing);
  });

  testWidgets('a runner being available shows the Run affordance', (
    tester,
  ) async {
    await _pump(
      tester,
      runners: const [
        api.CodeBlockRunner(
          moduleId: 'code-exec',
          command: 'run',
          language: 'javascript',
        ),
      ],
    );

    expect(find.bySemanticsLabel('Run with code-exec'), findsOneWidget);
  });

  testWidgets(
    'running posts the code and renders the output inline below the block',
    (tester) async {
      String? sentBody;
      await _pump(
        tester,
        runners: const [
          api.CodeBlockRunner(
            moduleId: 'code-exec',
            command: 'run',
            language: 'javascript',
          ),
        ],
        onRunRequest: (request) {
          expect(request.method, 'POST');
          expect(request.url.path, '/modules/code-exec/commands/run');
          sentBody = request.body;
          return _jsonResponse({'ok': true, 'output': '1'});
        },
      );

      await tester.tap(find.bySemanticsLabel('Run with code-exec'));
      await tester.pumpAndSettle();

      expect(jsonDecode(sentBody!)['input'], 'console.log(1)');
      expect(find.text('Result'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    },
  );

  testWidgets(
    "the module's own ok:false renders as error output, not AppErrorState",
    (tester) async {
      await _pump(
        tester,
        runners: const [
          api.CodeBlockRunner(
            moduleId: 'code-exec',
            command: 'run',
            language: 'javascript',
          ),
        ],
        onRunRequest: (_) =>
            _jsonResponse({'ok': false, 'error': 'syntax error'}),
      );

      await tester.tap(find.bySemanticsLabel('Run with code-exec'));
      await tester.pumpAndSettle();

      expect(find.text('Error'), findsOneWidget);
      expect(find.text('syntax error'), findsOneWidget);
      expect(find.byType(AppErrorState), findsNothing);
    },
  );

  testWidgets(
    'a transport-level failure surfaces via AppErrorState, never a SnackBar, '
    'and renders no output',
    (tester) async {
      await _pump(
        tester,
        runners: const [
          api.CodeBlockRunner(
            moduleId: 'code-exec',
            command: 'run',
            language: 'javascript',
          ),
        ],
        onRunRequest: (_) =>
            _jsonResponse({'error': 'module is not enabled'}, 409),
      );

      await tester.tap(find.bySemanticsLabel('Run with code-exec'));
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('Module is not enabled'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Result'), findsNothing);
      expect(find.text('Error'), findsNothing);
    },
  );

  testWidgets('a second run replaces the previous output rather than adding '
      'to it', (tester) async {
    var call = 0;
    await _pump(
      tester,
      runners: const [
        api.CodeBlockRunner(
          moduleId: 'code-exec',
          command: 'run',
          language: 'javascript',
        ),
      ],
      onRunRequest: (_) {
        call += 1;
        return _jsonResponse({'ok': true, 'output': 'run $call'});
      },
    );

    await tester.tap(find.bySemanticsLabel('Run with code-exec'));
    await tester.pumpAndSettle();
    expect(find.text('run 1'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Run with code-exec'));
    await tester.pumpAndSettle();
    expect(find.text('run 1'), findsNothing);
    expect(find.text('run 2'), findsOneWidget);
  });

  testWidgets(
    'a runner declared for a different language is never offered on this '
    'block',
    (tester) async {
      await _pump(
        tester,
        runners: const [
          api.CodeBlockRunner(
            moduleId: 'code-exec',
            command: 'run',
            language: 'python',
          ),
        ],
      );

      expect(find.bySemanticsLabel('Run with code-exec'), findsNothing);
    },
  );

  testWidgets(
    "a runner declared 'javascript' matches this block's 'js' fence tag "
    'through the alias map',
    (tester) async {
      await _pump(
        tester,
        runners: const [
          api.CodeBlockRunner(
            moduleId: 'code-exec',
            command: 'run',
            language: 'javascript',
          ),
        ],
      );

      expect(find.bySemanticsLabel('Run with code-exec'), findsOneWidget);
    },
  );

  /// The owner fenced a block as `python`, pressed Run, and got
  /// `ReferenceError: print is not defined` back from a JavaScript engine.
  /// Naming the module on the button was the first answer and it was not
  /// enough: the owner came back with "it shouldn't appear on ones it can't
  /// run", which is right. A runner that has not said what it runs is not a
  /// runner for this block.
  testWidgets('a runner that declares no language is offered for nothing', (
    tester,
  ) async {
    await _pump(
      tester,
      language: 'python',
      runners: const [
        api.CodeBlockRunner(moduleId: 'code-exec', command: 'run'),
      ],
    );

    expect(find.bySemanticsLabel('Run with code-exec'), findsNothing);
    expect(find.bySemanticsLabel('Run code'), findsNothing);
  });

  /// The same block with a runner that does claim python keeps its button,
  /// so this is about an undeclared language and not about python.
  testWidgets('a runner that declares the block language is still offered', (
    tester,
  ) async {
    await _pump(
      tester,
      language: 'python',
      runners: const [
        api.CodeBlockRunner(
          moduleId: 'py-exec',
          command: 'run',
          language: 'python',
        ),
      ],
    );

    expect(find.bySemanticsLabel('Run with py-exec'), findsOneWidget);
  });

  testWidgets('the first matching runner wins when several are discovered', (
    tester,
  ) async {
    String? postedModuleId;
    await _pump(
      tester,
      runners: const [
        api.CodeBlockRunner(
          moduleId: 'first',
          command: 'run',
          language: 'javascript',
        ),
        api.CodeBlockRunner(
          moduleId: 'second',
          command: 'run',
          language: 'javascript',
        ),
      ],
      onRunRequest: (request) {
        postedModuleId = request.url.pathSegments[1];
        return _jsonResponse({'ok': true, 'output': 'done'});
      },
    );

    await tester.tap(find.bySemanticsLabel('Run with first'));
    await tester.pumpAndSettle();

    expect(postedModuleId, 'first');
  });

  testWidgets(
    'a scene step in a message goes through the shared message-scoped route, '
    'not the ephemeral one, so every viewer sees it',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String scene(String state) =>
          '{"\$slim":"scene/1","width":3,"height":3,'
          '"ops":[{"op":"cells","cols":3,"rows":3,"data":"000010000",'
          '"palette":["sunken","accent"],"tap":"toggle"}],'
          '"controls":["step"],"state":"$state","live":true}';
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final paths = <String>[];
      await _pump(
        tester,
        messageId: 'm1',
        events: events.stream,
        runners: const [
          api.CodeBlockRunner(
            moduleId: 'game-of-life',
            command: 'life',
            language: 'javascript',
          ),
        ],
        onRunRequest: (request) {
          paths.add(request.url.path);
          // The shared render comes from the broadcast (extras), so feed one.
          events.add(
            api.CodeRunChanged(
              channelId: 'c1',
              messageId: 'm1',
              run: api.CodeRun(
                blockIndex: 0,
                moduleId: 'game-of-life',
                command: 'life',
                ok: true,
                output: scene('s${paths.length}'),
                ranBy: 'u1',
                ranAt: 1700000000000 + paths.length,
              ),
            ),
          );
          return _jsonResponse({
            'ok': true,
            'output': scene('s${paths.length}'),
          });
        },
      );

      await tester.tap(find.bySemanticsLabel('Run with game-of-life'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step forward'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Step forward'));
      await tester.pumpAndSettle();

      expect(paths, isNotEmpty);
      expect(paths, everyElement('/messages/m1/blocks/0/run'));
      expect(
        paths.any((p) => p.contains('/commands/')),
        isFalse,
        reason: 'a step must not hit the ephemeral per-caller run endpoint',
      );
    },
  );

  testWidgets('a shared run shows its output from the POST response when no '
      'CodeRunChanged event is delivered', (tester) async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    await _pump(
      tester,
      messageId: 'm1',
      events: events.stream,
      runners: const [
        api.CodeBlockRunner(
          moduleId: 'code-exec',
          command: 'run',
          language: 'javascript',
        ),
      ],
      onRunRequest: (request) =>
          _jsonResponse({'ok': true, 'output': 'long job done'}),
    );

    await tester.tap(find.bySemanticsLabel('Run with code-exec'));
    await tester.pumpAndSettle();

    expect(find.text('long job done'), findsOneWidget);
  });
}
