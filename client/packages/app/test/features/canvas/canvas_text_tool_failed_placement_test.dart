// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text box whose placement fails reopens its editor with the typed text,
/// and a second placement while one saves says so instead of vanishing.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_quick_placement.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_text_tool.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_text_editor.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _FakeEngine implements CanvasEngine {
  _FakeEngine(this.document);

  @override
  final CanvasDocument document;
  final errors = <String>[];

  @override
  String? get error => null;

  @override
  void reportError(String? message) => errors.add(message ?? '');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CanvasQuickPlacement _placement(CanvasDocument document, int status) =>
    CanvasQuickPlacement(
      client: testApi(
        (request) async => http.Response('{"error":"no"}', status),
      ),
      channelId: 'c1',
      document: document,
      timedOutUntil: () => null,
    );

void main() {
  testWidgets('a failed text placement reopens the editor with the text', (
    tester,
  ) async {
    final document = CanvasDocument();
    final engine = _FakeEngine(document);
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
    final tool = CanvasTextTool(
      engine: engine,
      placement: () => _placement(document, 409),
      ref: ref,
      currentTool: () => CanvasTool.text,
      changed: ([mutate]) => mutate?.call(),
      onPlaced: (_, _) {},
      focusBoard: () {},
      spectating: () => false,
    );
    const at = Offset(40, 50);
    tool.place(at);
    final editor =
        tool.editor(
              null,
              onCancel: () {},
              onEscape: () {},
              onEditClosed: () {},
            )!
            as CanvasTextEditor;

    await tester.runAsync(() async {
      editor.onSave(editor.initial.copyWith(text: 'a long paragraph'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    final reopened = tool.editor(
      null,
      onCancel: () {},
      onEscape: () {},
      onEditClosed: () {},
    );
    expect(tool.draft, at);
    expect((reopened! as CanvasTextEditor).initial.text, 'a long paragraph');
    expect(engine.errors, isNotEmpty);
  });

  test(
    'a second placement while one saves reports instead of vanishing',
    () async {
      final gate = Completer<http.Response>();
      final placement = CanvasQuickPlacement(
        client: testApi((request) => gate.future),
        channelId: 'c1',
        document: CanvasDocument(),
        timedOutUntil: () => null,
      );
      final messages = <String>[];
      const offer = api.CanvasTileOffer(moduleId: 'm', tile: 't');

      unawaited(placement.placeModuleTile(Offset.zero, offer, onError: (_) {}));
      final second = await placement.placeModuleTile(
        const Offset(300, 300),
        offer,
        onError: messages.add,
      );

      expect(second, isNull);
      expect(messages, ['Still saving the last item.']);
      gate.complete(http.Response('{"error":"no"}', 409));
    },
  );
}
