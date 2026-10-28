// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What starting a screen share needs before capture begins: the source and
/// the space's quality ceiling.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_rtc/rtc.dart' show ScreenShareSource;

import '../../../providers/providers.dart' show apiProvider;
import '../providers/screen_share_ceiling.dart';
import '../providers/voice_controller.dart';
import 'screen_source_sheet.dart';

Future<({bool proceed, String? id, ScreenShareSource? source})> pickShareSource(
  BuildContext context,
  VoiceController controller, {
  required String? lastSourceId,
}) async {
  if (!controller.screenShareNeedsSource) {
    return (proceed: true, id: null, source: null);
  }
  // Mandatory: capture cannot find a source nothing asked to list.
  final sources = await controller.screenShareSources();
  if (sources.isEmpty) return (proceed: false, id: null, source: null);
  // On Linux the portal's own picker is the real choice; see DesktopSources.
  if (sources.length == 1 || !controller.screenShareSourcePickerUseful) {
    return (proceed: true, id: sources.first.id, source: sources.first);
  }
  if (!context.mounted) return (proceed: false, id: null, source: null);
  final chosen = await showScreenSourceSheet(
    context,
    sources,
    selectedId: lastSourceId,
  );
  return (proceed: chosen != null, id: chosen?.id, source: chosen);
}

/// The space-wide screen-share ceiling; see [screenShareCeilingFrom].
Future<int?> screenShareCeiling(WidgetRef ref) =>
    screenShareCeilingFrom(ref.read(apiProvider));
