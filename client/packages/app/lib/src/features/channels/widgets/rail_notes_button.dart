// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The way into Notes, the personal space: a button beside the rail's gear.
/// See docs/decisions/0111-personal-space-is-called-notes.md.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/channel_by_id_provider.dart';
import '../providers/dms.dart';
import '../../../routing/routes.dart';
import '../../../widgets/run_guarded.dart';
import '../../../widgets/shortcut_label.dart';

/// Why the last attempt to open Notes failed, shown over the rail until dismissed.
final notesOpenFailureProvider = StateProvider<String?>((ref) => null);

/// Where Notes was opened from, so a second press goes back there.
final notesReturnLocationProvider = StateProvider<String?>((ref) => null);

/// Toggles Notes in [router]: opens it, creating it on the server the first
/// time this account has none, or leaves it for where it was opened from.
/// Shared by the button and its shortcut.
Future<void> openNotes(ProviderContainer container, GoRouter router) async {
  final here = router.routerDelegate.currentConfiguration.uri.toString();
  String? channelId;
  final failure = await runGuarded(
    whatFailed: 'open Notes',
    action: () async => channelId = await openPersonalSpace(container),
  );
  container.read(notesOpenFailureProvider.notifier).state = failure;
  final id = channelId;
  if (failure != null || id == null) return;
  final notes = Routes.channel(id);
  final back = container.read(notesReturnLocationProvider.notifier);
  if (Uri.parse(here).path == notes) {
    router.go(back.state ?? Routes.channels);
    back.state = null;
    return;
  }
  back.state = here;
  router.go(notes);
}

/// Shows as active while Notes is the channel on screen.
class RailNotesButton extends ConsumerStatefulWidget {
  const RailNotesButton({super.key, required this.activeChannelId});

  final String? activeChannelId;

  @override
  ConsumerState<RailNotesButton> createState() => _RailNotesButtonState();
}

class _RailNotesButtonState extends ConsumerState<RailNotesButton> {
  /// A first open waits on the server, and a second tap must not ask twice.
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final router = GoRouter.of(context);
    _opening = true;
    try {
      await openNotes(container, router);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.activeChannelId;
    final open =
        id != null &&
        ref.watch(
          channelByIdProvider(
            id,
          ).select((c) => c.valueOrNull?.isPersonalSpace ?? false),
        );
    return AppIconButton(
      icon: AppIcons.notebook,
      semanticLabel: 'Notes',
      tooltip: labelWithShortcut('Notes', AppAction.openNotes),
      // Null while closed, so a screen reader hears a plain button rather than a toggle that is off.
      active: open ? true : null,
      onPressed: () => unawaited(_open()),
    );
  }
}
