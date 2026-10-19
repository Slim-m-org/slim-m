// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What starting a screen share needs before capture begins: the source and
/// the space's quality ceiling.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

import '../../../providers/providers.dart' show apiProvider;
import '../providers/voice_controller.dart';
import 'screen_source_sheet.dart';

Future<({bool proceed, String? id})> pickShareSource(
  BuildContext context,
  VoiceController controller, {
  required String? lastSourceId,
}) async {
  if (!controller.screenShareNeedsSource) return (proceed: true, id: null);
  // Mandatory: capture cannot find a source nothing asked to list.
  final sources = await controller.screenShareSources();
  if (sources.isEmpty) return (proceed: false, id: null);
  // On Linux the portal's own picker is the real choice; see DesktopSources.
  if (sources.length == 1 || !controller.screenShareSourcePickerUseful) {
    return (proceed: true, id: sources.first.id);
  }
  if (!context.mounted) return (proceed: false, id: null);
  final chosen = await showScreenSourceSheet(
    context,
    sources,
    selectedId: lastSourceId,
  );
  return (proceed: chosen != null, id: chosen?.id);
}

/// The space-wide screen-share ceiling, or `null` on any failure to fetch
/// it, or on a server too old to report one. Read from `GET /version`,
/// unauthenticated, rather than the MANAGE_SERVER-gated
/// `GET /space/screen-share` the admin screen uses: every device sharing a
/// screen has to know this, not only one with an admin bit. This is a
/// client-advertised courtesy cap, not a security boundary, so a Space
/// this device cannot reach right now must not be the reason a share never
/// starts: failing open publishes at the quality already chosen, exactly
/// what happened before this setting existed.
Future<int?> screenShareCeiling(WidgetRef ref) async {
  try {
    final version = await ref.read(apiProvider).version();
    return version.screenShareMaxHeight;
  } catch (error, stack) {
    reportFailure(
      LogTag.voice,
      "read the server's screen share quality limit",
      error,
      stack,
    );
    return null;
  }
}
