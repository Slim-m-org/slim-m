// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The object menu of a connection (decision 0137): its label and Delete. Bring to front and Send to back stay out, since a connection is only ordered among connections; colour and arrow live in the bar the selection shows.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// The connection under [point], resolved the way a click selects it, or null when an object sits above or nothing is there.
String? edgeUnder(CanvasDocument document, Offset point, {bool touch = false}) {
  if (hitTestTopmost(document, point, touch: touch) != null) return null;
  return document.edges.hitEdge(
    point,
    zoom: document.camera.zoom,
    touch: touch,
  );
}

Widget canvasEdgeMenu({
  required String id,
  required bool canEdit,
  required VoidCallback onEditLabel,
  required VoidCallback onDelete,
}) => AppMenu(
  width: 200,
  children: [
    AppMenuItem(
      label: 'Edit label',
      leading: AppIcons.edit,
      onTap: canEdit ? onEditLabel : null,
    ),
    AppMenuItem(
      label: 'Delete',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: canEdit ? onDelete : null,
    ),
  ],
);
