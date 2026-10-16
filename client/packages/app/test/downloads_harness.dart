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
  final bytes = <int>[];
  bool finished = false;
  bool discarded = false;

  @override
  Future<void> write(List<int> chunk) async => bytes.addAll(chunk);

  @override
  Future<void> finish() async => finished = true;

  @override
  Future<void> discard() async => discarded = true;
}

/// Stands in for the Save dialog and keeps every target it handed out.
class FakeSaveDialog {
  final targets = <FakeTarget>[];
  final filenames = <String>[];

  /// Set to answer "dismissed".
  bool dismiss = false;

  Future<DownloadTarget?> call(String filename) async {
    if (dismiss) return null;
    filenames.add(filename);
    return FakeTarget().._remember(targets);
  }
}

extension on FakeTarget {
  void _remember(List<FakeTarget> into) => into.add(this);
}

/// An API whose attachment GET answers with [body], or [status] when not 200.
class FakeAttachmentServer {
  FakeAttachmentServer({this.status = 200, this.contentLength});

  final int status;
  final int? contentLength;
  final body = StreamController<List<int>>();
  bool bodyCancelled = false;
  int requests = 0;

  api.SlimmApi client() => api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: api.SessionStore(tokens: testTokens),
    httpClient: MockClient.streaming((request, _) async {
      requests++;
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
  FakeSaveDialog dialog,
) {
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(server.client()),
      downloadTargetOpenerProvider.overrideWithValue(dialog.call),
    ],
  );
  return container;
}
