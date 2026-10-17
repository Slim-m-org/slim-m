// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Downloads run from an app-scoped controller: they stream to the chosen
/// target, report progress, survive the widgets that started them, and every
/// way of stopping one closes the connection and removes the partial file.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/downloads_controller.dart';

import 'downloads_harness.dart';

const _iso = api.Attachment(
  id: 'iso1',
  filename: 'Win11.iso',
  contentType: 'application/octet-stream',
  size: 8,
);

void main() {
  late FakeAttachmentServer server;
  late FakeSaveDialog dialog;
  late ProviderContainer container;

  void harness({int status = 200, Duration? stall, api.SessionStore? session}) {
    server = FakeAttachmentServer(status: status, contentLength: 8);
    dialog = FakeSaveDialog();
    container = downloadsContainer(
      server,
      dialog,
      stall: stall,
      session: session,
    );
    addTearDown(container.dispose);
    container.listen(downloadsProvider, (_, _) {});
  }

  DownloadsController controller() =>
      container.read(downloadsProvider.notifier);
  List<DownloadTask> tasks() => container.read(downloadsProvider);

  late Future<void> run;

  /// Starts a download into [run] and waits until its body is being read.
  Future<void> begin() async {
    run = controller().start(_iso);
    await until(() => server.body.hasListener);
  }

  test('streams every chunk to the target and finishes', () async {
    harness();
    await begin();
    final started = run;
    server.body.add([1, 2, 3, 4]);
    await until(() => dialog.targets.single.bytes.length == 4);
    expect(tasks().single.running, isTrue);
    server.body.add([5, 6, 7, 8]);
    await server.body.close();
    await started;

    final target = dialog.targets.single;
    expect(target.bytes, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(target.finished, isTrue);
    expect(tasks().single.phase, DownloadPhase.done);
    expect(tasks().single.received, 8);
  });

  test('a dismissed Save dialog starts nothing', () async {
    harness();
    dialog.dismiss = true;
    await controller().start(_iso);
    expect(tasks(), isEmpty);
    expect(server.requests, 0);
  });

  test('a dialog that throws leaves a failed row', () async {
    harness();
    dialog.explode = true;
    await controller().start(_iso);
    expect(tasks().single.phase, DownloadPhase.failed);
    expect(tasks().single.message, 'Could not save Win11.iso.');
  });

  test('two quick clicks open one dialog and start one download', () async {
    harness();
    dialog.hold = Completer<void>();
    final first = controller().start(_iso);
    await until(() => dialog.filenames.isNotEmpty);
    await controller().start(_iso);
    expect(dialog.filenames, hasLength(1));
    dialog.hold!.complete();
    await until(() => server.body.hasListener);
    expect(server.requests, 1);
    await controller().cancel(tasks().single.id);
    await first;
  });

  test('the same attachment is not downloaded twice at once', () async {
    harness();
    await begin();
    final started = run;
    await controller().start(_iso);
    expect(tasks(), hasLength(1));
    expect(server.requests, 1);
    await controller().cancel(tasks().single.id);
    await started;
  });

  test('cancel closes the response and deletes the partial file', () async {
    harness();
    await begin();
    final started = run;
    server.body.add([1, 2, 3]);
    await until(() => dialog.targets.single.bytes.length == 3);

    await controller().cancel(tasks().single.id);
    await started;

    await until(() => server.bodyCancelled);
    expect(dialog.targets.single.discarded, isTrue);
    expect(dialog.targets.single.finished, isFalse);
    expect(tasks(), isEmpty);
  });

  test('cancelling before the headers arrive still closes the body', () async {
    harness();
    server.headersGate = Completer<void>();
    final started = controller().start(_iso);
    await until(() => server.requests == 1 && tasks().isNotEmpty);

    await controller().cancel(tasks().single.id);
    server.headersGate!.complete();
    await started;

    await until(() => server.bodyCancelled);
    expect(dialog.targets.single.discarded, isTrue);
    expect(tasks(), isEmpty);
  });

  test('a refused download fails with a sentence and leaves no file', () async {
    harness(status: 403);
    await controller().start(_iso);

    final task = tasks().single;
    expect(task.phase, DownloadPhase.failed);
    expect(task.message, contains('Could not download Win11.iso'));
    expect(dialog.targets.single.discarded, isTrue);
  });

  test(
    'a connection that dies mid-body fails and deletes the partial',
    () async {
      harness();
      await begin();
      final started = run;
      server.body.add([1, 2]);
      server.body.addError(const api.TransportException('reset'));
      await started;

      expect(tasks().single.phase, DownloadPhase.failed);
      expect(dialog.targets.single.discarded, isTrue);
    },
  );

  test(
    'a stalled body fails, discards the partial and cancels the source',
    () async {
      harness(stall: const Duration(milliseconds: 30));
      final started = controller().start(_iso);
      await started;

      expect(tasks().single.phase, DownloadPhase.failed);
      expect(dialog.targets.single.discarded, isTrue);
      await until(() => server.bodyCancelled);
    },
  );

  test('a target that cannot write fails and closes the connection', () async {
    harness();
    dialog.make = () => FakeTarget()..failWrite = true;
    await begin();
    final started = run;
    server.body.add([1, 2]);
    await started;

    expect(tasks().single.phase, DownloadPhase.failed);
    expect(dialog.targets.single.discarded, isTrue);
    await until(() => server.bodyCancelled);
  });

  test('a target that cannot finish fails and discards', () async {
    harness();
    dialog.make = () => FakeTarget()..failFinish = true;
    await begin();
    final started = run;
    server.body.add([1]);
    await server.body.close();
    await started;

    expect(tasks().single.phase, DownloadPhase.failed);
    expect(dialog.targets.single.discarded, isTrue);
  });

  test(
    'a dismissed final save step removes the row instead of saying saved',
    () async {
      harness();
      dialog.make = () => FakeTarget()..saved = false;
      await begin();
      final started = run;
      server.body.add([1]);
      await server.body.close();
      await started;

      expect(tasks(), isEmpty);
    },
  );

  test('a target too small for the file refuses before downloading', () async {
    harness();
    dialog.make = () => FakeTarget(limit: 4);
    await controller().start(_iso);

    expect(tasks().single.phase, DownloadPhase.failed);
    expect(tasks().single.message, contains('too large'));
    expect(server.requests, 0);
    expect(dialog.targets.single.discarded, isTrue);
  });

  test('retrying replaces the failed row and downloads again', () async {
    harness();
    dialog.make = () => FakeTarget()..failWrite = dialog.targets.isEmpty;
    await begin();
    var started = run;
    server.body.add([1]);
    await started;
    expect(tasks().single.phase, DownloadPhase.failed);

    started = controller().start(_iso);
    await until(() => server.requests == 2 && server.body.hasListener);

    expect(tasks(), hasLength(1));
    expect(tasks().single.running, isTrue);
    server.body.add([1, 2, 3, 4, 5, 6, 7, 8]);
    await server.body.close();
    await started;
    expect(tasks().single.phase, DownloadPhase.done);
  });

  test(
    'dismiss removes a row, and a new download prunes finished ones',
    () async {
      harness();
      await begin();
      var started = run;
      await server.body.close();
      await started;
      expect(tasks().single.phase, DownloadPhase.done);

      started = controller().start(_iso);
      await until(() => server.requests == 2 && server.body.hasListener);
      expect(tasks(), hasLength(1));
      expect(tasks().single.running, isTrue);

      controller().dismiss(tasks().single.id);
      expect(tasks(), isEmpty);
      await server.body.close();
      await started;
    },
  );

  test(
    'disposing the container cancels runs and discards partial files',
    () async {
      harness();
      await begin();
      final started = run;
      server.body.add([1]);
      await until(() => dialog.targets.single.bytes.isNotEmpty);

      container.dispose();
      await started;

      await until(() => server.bodyCancelled);
      expect(dialog.targets.single.discarded, isTrue);
    },
  );

  test(
    'signing out clears the rows and cancels the running download',
    () async {
      final session = api.SessionStore(tokens: testTokens);
      harness(session: session);
      await begin();
      final started = run;
      server.body.add([1]);
      await until(() => dialog.targets.single.bytes.isNotEmpty);

      session.set(null);
      await started;

      await until(() => server.bodyCancelled);
      expect(dialog.targets.single.discarded, isTrue);
      expect(tasks(), isEmpty);
    },
  );
}
