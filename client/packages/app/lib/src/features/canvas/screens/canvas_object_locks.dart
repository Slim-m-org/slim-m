// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which canvas objects are locked in place: fetched on open and on every
/// reconnect, kept current by `canvas.object.lock_changed` frames, the same
/// shape `CanvasMediaSlotSync` uses for tile state. A locked object is passed
/// through by a drag or an erase, so a photo can be layered or drawn on top.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class CanvasObjectLocks {
  CanvasObjectLocks({required this.channelId, required this.client});

  final String channelId;
  final api.SlimmApi client;

  /// The locked object ids, replaced as a whole on every change.
  final ValueNotifier<Set<String>> ids = ValueNotifier(const {});

  bool isLocked(String objectId) => ids.value.contains(objectId);

  // A fetch or a lock call can still be in flight when the pane closes.
  bool _disposed = false;

  /// A failed read leaves the last known set standing rather than blocking the canvas.
  Future<void> fetch() async {
    final Set<String> fetched;
    try {
      fetched = await client.canvasObjectLocks(channelId);
    } on api.ApiException {
      return;
    }
    if (!_disposed) ids.value = fetched;
  }

  void applyRemote(api.CanvasObjectLockChanged event) {
    if (event.channelId != channelId) return;
    _set(event.objectId, event.locked);
  }

  /// Locks or unlocks [objectId] at once and reverts if the server refuses.
  /// Returns false on a refusal, so the caller can say it did not stick.
  Future<bool> setLocked(String objectId, bool locked) async {
    final before = ids.value;
    _set(objectId, locked);
    try {
      if (locked) {
        await client.lockCanvasObject(channelId, objectId);
      } else {
        await client.unlockCanvasObject(channelId, objectId);
      }
      return true;
    } on api.ApiException {
      if (!_disposed) ids.value = before;
      return false;
    }
  }

  void _set(String objectId, bool locked) {
    final next = {...ids.value};
    final changed = locked ? next.add(objectId) : next.remove(objectId);
    if (changed) ids.value = next;
  }

  void dispose() {
    _disposed = true;
    ids.dispose();
  }
}

/// Hands [CanvasObjectLocks] to the context menu and the lock badges without
/// threading it through every pane constructor.
class CanvasObjectLocksScope extends InheritedWidget {
  const CanvasObjectLocksScope({
    super.key,
    required this.locks,
    required super.child,
  });

  final CanvasObjectLocks locks;

  static CanvasObjectLocks? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CanvasObjectLocksScope>()
      ?.locks;

  @override
  bool updateShouldNotify(CanvasObjectLocksScope oldWidget) =>
      locks != oldWidget.locks;
}

/// A small lock on each locked object's top-left corner, so a layer that
/// passes the pointer through says why. Draws nothing and takes no pointer.
class CanvasObjectLockBadges extends StatelessWidget {
  const CanvasObjectLockBadges({
    super.key,
    required this.document,
    required this.locks,
  });

  final CanvasDocument document;
  final CanvasObjectLocks locks;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge([document, locks.ids]),
        builder: (context, _) {
          final camera = document.camera;
          return Stack(
            children: [
              for (final id in locks.ids.value)
                if (document.objectBounds(id) case final b?)
                  Positioned(
                    key: ValueKey('canvas-lock-badge-$id'),
                    left: (b.x - camera.x) * camera.zoom + AppSpacing.s4,
                    top: (b.y - camera.y) * camera.zoom + AppSpacing.s4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.surfaceRaised,
                        borderRadius: BorderRadius.circular(AppRadii.control),
                        border: Border.all(color: tokens.borderSubtle),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.s4),
                        child: Icon(
                          AppIcons.tileLocked,
                          size: AppSizes.icon16,
                          color: tokens.textSecondary,
                          semanticLabel: 'Locked in place',
                        ),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}
