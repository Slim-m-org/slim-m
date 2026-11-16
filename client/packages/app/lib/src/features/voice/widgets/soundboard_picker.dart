// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The clips a call member can play, listed inside the soundboard menu.
///
/// Playing only asks the server to tell the call; the sound comes back as an
/// event every client in the call, this one included, plays for itself. The
/// server's one play per person every 3 seconds shows as the rows resting,
/// the way slow mode rests Send, never as an error.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/soundboard_actions.dart';
import '../providers/soundboard_clips.dart';

/// The tallest the clip list grows before it scrolls.
const double soundboardListMaxHeight = 288;

/// How long the server makes one person wait between plays (decision 0118).
const soundboardPlayCooldown = Duration(seconds: 3);

class SoundboardPicker extends ConsumerStatefulWidget {
  const SoundboardPicker({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<SoundboardPicker> createState() => _SoundboardPickerState();
}

class _SoundboardPickerState extends ConsumerState<SoundboardPicker>
    with GuardedActionState<SoundboardPicker> {
  Timer? _cooldown;

  bool get _resting => _cooldown?.isActive ?? false;

  void _rest(Duration wait) {
    _cooldown?.cancel();
    setState(() {
      _cooldown = Timer(wait, () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  Future<void> _play(api.SoundClip clip) async {
    if (_resting) return;
    _rest(soundboardPlayCooldown);
    final ok = await guard(
      whatFailed: 'play ${clip.name}',
      action: () async {
        try {
          await ref
              .read(soundboardActionsProvider)
              .play(widget.channelId, clip.id);
        } on api.RateLimitedException catch (e) {
          // The server is still counting an earlier play: that is the rest already shown.
          if (mounted) _rest(e.retryAfter ?? soundboardPlayCooldown);
        }
      },
    );
    if (!ok && mounted) setState(() => _cooldown?.cancel());
  }

  @override
  Widget build(BuildContext context) {
    final clips = ref.watch(soundClipsProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppAsyncView<List<api.SoundClip>>(
      value: AppAsyncState(data: clips.valueOrNull, error: clips.error),
      center: false,
      errorMessage: 'Could not load the soundboard.',
      onRetry: () => ref.invalidate(soundClipsProvider),
      data: (context, list) {
        if (list.isEmpty) {
          return AppMenuControl(
            child: Text(
              'No clips yet. An admin can add some in Space settings.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (actionError != null)
              AppMenuControl(
                child: AppErrorState(
                  message: actionError!,
                  onDismiss: clearActionError,
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: soundboardListMaxHeight,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final clip in list)
                      AppMenuItem(
                        key: ValueKey(clip.id),
                        label: clip.name,
                        leading: AppIcons.play,
                        trailing: AppMenuValue(
                          formatClipLength(clip.durationMs),
                        ),
                        onTap: _resting ? null : () => unawaited(_play(clip)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
