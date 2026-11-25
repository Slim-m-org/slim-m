// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overflow menu's "Export canvas..." row: when the board may be exported, and how it opens the sheet.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show ChannelKinds;

import '../../channels/providers/channel_by_id_provider.dart';
import '../providers/canvas_export.dart';
import '../widgets/canvas_export_sheet.dart';
import 'canvas_module_tile_scope.dart';

/// Whether this board offers the row: a voice canvas or a canvas channel, on a server that can export, never a DM or a personal space.
bool canvasExportOffered(BuildContext context, WidgetRef ref) {
  final channelId = CanvasModuleTileScope.maybeOf(context)?.channelId;
  if (channelId == null || !ref.watch(canvasExportSupportedProvider)) {
    return false;
  }
  final row = ref.watch(channelByIdProvider(channelId)).valueOrNull;
  if (row == null || row.isPersonalSpace || row.parentMessageId != null) {
    return false;
  }
  return row.hasCanvas && (row.kind == 'voice' || row.kind == 'canvas');
}

/// Opens the sheet for the board [context] sits in; nothing when it sits in none.
Future<void> openCanvasExport(BuildContext context) async {
  final channelId = CanvasModuleTileScope.maybeOf(context)?.channelId;
  if (channelId == null) return;
  await showCanvasExportSheet(context, channelId);
}
