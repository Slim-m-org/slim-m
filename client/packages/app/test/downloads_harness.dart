// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fakes for the download tests: a Save target that records what it is given,
/// and an API whose attachment response a test feeds by hand.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/download_target.dart';
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';

const testTokens = api.TokenPair(
  userId: 'u1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class FakeTarget implements DownloadTarget {
  FakeTarget({this.limit});

  final int? limit;
  final bytes = <int>[];
  bool finished = false;
  bool discarded = false;

  /// Set to make the next write or finish throw, or finish answer "dismissed".
  bool failWrite = false;
  bool failFinish = false;
  bool saved = true;

  @override
  int? get maxBytes => limit;

  @override
  Future<void> write(List<int> chunk) async {
    if (failWrite) throw StateError('disk full');
    bytes.addAll(chunk);
  }

  @override
  Future<bool> finish() async {
    if (failFinish) throw StateError('disk full');
    finished = true;
    return saved;
  }

  @override
  Future<void> discard() async => discarded = true;
}

/// Stands in for the Save dialog and keeps every target it handed out.
class FakeSaveDialog {
  final targets = <FakeTarget>[];
  final filenames = <String>[];

  /// Set to answer "dismissed".
  bool dismiss = false;

  /// Set to make the dialog itself throw.
  bool explode = false;

  /// When set, the dialog stays open until this completes.
  Completer<void>? hold;

  /// Applied to each new target.
  FakeTarget Function() make = FakeTarget.new;

  Future<DownloadTarget?> call(String filename) async {
    filenames.add(filename);
    if (explode) throw StateError('no portal');
    await hold?.future;
    if (dismiss) return null;
    final target = make();
    targets.add(target);
    return target;
  }
}

/// An API whose attachment GET answers with [body], or [status] when not 200.
class FakeAttachmentServer {
  FakeAttachmentServer({this.status = 200, this.contentLength});

  final int status;
  final int? contentLength;
  StreamController<List<int>> body = StreamController<List<int>>();
  bool bodyCancelled = false;
  int requests = 0;

  /// When set, response headers wait for it.
  Completer<void>? headersGate;

  api.SlimmApi client() => api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: api.SessionStore(tokens: testTokens),
    httpClient: MockClient.streaming((request, _) async {
      requests++;
      await headersGate?.future;
      if (requests > 1) body = StreamController<List<int>>();
      if (status != 200) {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"error":"forbidden"}')),
          status,
        );
      }
      body.onCancel = () {
        bodyCancelled = true;
      };
      return http.StreamedResponse(
        body.stream,
        200,
        contentLength: contentLength,
      );
    }),
  );
}

ProviderContainer downloadsContainer(
  FakeAttachmentServer server,
  FakeSaveDialog dialog, {
  Duration? stall,
  DateTime Function()? clock,
  api.SessionStore? session,
}) => ProviderContainer(
  overrides: [
    sessionProvider.overrideWithValue(
      session ?? api.SessionStore(tokens: testTokens),
    ),
    apiProvider.overrideWithValue(server.client()),
    downloadTargetOpenerProvider.overrideWithValue(dialog.call),
    if (stall != null) downloadStallProvider.overrideWithValue(stall),
    if (clock != null) downloadClockProvider.overrideWithValue(clock),
  ],
);

/// Lets the event loop turn until [condition] holds; no wall-clock sleeping.
Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!condition()) throw StateError('condition never held');
}
