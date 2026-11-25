// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Exporting a board into a new canvas channel: whether the server can, the request, and what a failed try tells the person.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../../providers/server_info.dart';

/// Whether this server can export a board; an older one offers no entry.
final canvasExportSupportedProvider = Provider.autoDispose<bool>(
  (ref) =>
      ref.watch(serverInfoProvider).valueOrNull?.supportsCanvasExport ?? false,
);

final canvasExporterProvider = Provider<CanvasExporter>(CanvasExporter.new);

class CanvasExporter {
  CanvasExporter(this._ref);

  final Ref _ref;

  /// Sends the export and files the new channel in the local store, so it is in the rail before its live event.
  Future<api.CanvasExportResult> export(
    String sourceId, {
    required String id,
    required String name,
    required String? categoryId,
    required bool voiceEnabled,
    required bool clearSource,
  }) async {
    final result = await _ref
        .read(apiProvider)
        .exportCanvas(
          sourceId,
          id: id,
          name: name,
          categoryId: categoryId,
          voiceEnabled: voiceEnabled,
          clearSource: clearSource,
        );
    final store = await _ref.read(storeProvider.future);
    await store.upsertChannels([result.channel]);
    return result;
  }
}

/// What a failed export means for the person looking at the sheet.
enum CanvasExportFailureKind {
  /// The server answered with an error: the two halves commit together, so nothing changed.
  refused,

  /// No answer came, so the outcome is unknown; trying again with the same id finishes or returns the one that happened.
  unreachable,

  /// More objects than one export copies; trying again cannot help.
  tooLarge,

  /// Another export of this board is running.
  busy,
}

class CanvasExportFailure {
  const CanvasExportFailure(this.kind, this.message);

  final CanvasExportFailureKind kind;

  /// The sentence to show; for [CanvasExportFailureKind.refused] the server's own reason.
  final String message;

  /// Whether the sheet offers the same request again.
  bool get canRetry => kind != CanvasExportFailureKind.tooLarge;

  static const tooLargeMessage = 'This canvas is too big to export.';
  static const busyMessage = 'This canvas is being exported already.';
  static const unreachableMessage =
      "Couldn't reach the server. Try again; it won't make a second copy.";
  static const nothingChanged = 'Nothing was changed.';

  static const stillFinishingMessage =
      "The first try may still be finishing. Try again; it won't make a second copy.";

  /// [afterUnknown] is true once an earlier try got no answer: a refusal or busy then may be that try still committing, so nothing is claimed unchanged.
  factory CanvasExportFailure.of(Object error, {bool afterUnknown = false}) {
    final failure = CanvasExportFailure._of(error);
    final ambiguous =
        failure.kind == CanvasExportFailureKind.refused ||
        failure.kind == CanvasExportFailureKind.busy;
    if (afterUnknown && ambiguous) {
      return const CanvasExportFailure(
        CanvasExportFailureKind.unreachable,
        stillFinishingMessage,
      );
    }
    return failure;
  }

  static CanvasExportFailure _of(Object error) {
    return switch (error) {
      api.ConflictException(code: api.CanvasExportRefusal.tooLarge) =>
        const CanvasExportFailure(
          CanvasExportFailureKind.tooLarge,
          tooLargeMessage,
        ),
      api.ConflictException(code: api.CanvasExportRefusal.busy) =>
        const CanvasExportFailure(CanvasExportFailureKind.busy, busyMessage),
      api.TransportException() ||
      api.UnavailableException() ||
      api.ServerException(
        statusCode: 502 || 503 || 504,
      ) => const CanvasExportFailure(
        CanvasExportFailureKind.unreachable,
        unreachableMessage,
      ),
      api.ApiException() => CanvasExportFailure(
        CanvasExportFailureKind.refused,
        '${_reason(error)} $nothingChanged',
      ),
      _ => const CanvasExportFailure(
        CanvasExportFailureKind.unreachable,
        unreachableMessage,
      ),
    };
  }

  static String _reason(api.ApiException error) {
    final message = error.message.trim();
    if (message.isEmpty) return 'The export was refused.';
    final sentence = message[0].toUpperCase() + message.substring(1);
    return sentence.endsWith('.') ? sentence : '$sentence.';
  }
}
