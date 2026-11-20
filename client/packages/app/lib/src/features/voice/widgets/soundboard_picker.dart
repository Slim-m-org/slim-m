// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The clips a call member can play, as a grid of small tiles in the
/// soundboard menu: each clip's emoji over its name, like an emoji picker.
///
/// Playing only asks the server to tell the call; the sound comes back as an
/// event every client in the call, this one included, plays for itself. The
/// server's one play per person every 3 seconds shows as the tiles resting,
/// the way slow mode rests Send, never as an error.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../../emoji/widgets/stored_emoji.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/soundboard_actions.dart';
import '../providers/soundboard_clips.dart';
import 'soundboard_volume_row.dart';

/// The popover's width: three tiles across, each wide enough for a starter
/// clip's name.
const double soundboardMenuWidth = 288;

/// How long the server makes one person wait between plays (decision 0118).
const soundboardPlayCooldown = Duration(seconds: 3);

/// Tiles in a popover row; a sheet fits as many as [_tileMinWidth] allows.
const _popoverColumns = 3;

const double _gap = AppSpacing.s4;

/// A tile's padding on every side, and the space between its emoji and name.
const double _inset = AppSpacing.s4;

/// Rows shown whole before the half row that says the list scrolls.
const _wholeRows = 5;

/// The narrowest tile a sheet gives a name, measured on a long starter one.
double _tileMinWidth(BuildContext context) {
  final name = TextPainter(
    text: TextSpan(
      text: 'wrong buzzer',
      style: DefaultTextStyle.of(context).style.merge(AppText.caption),
    ),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = name.width;
  name.dispose();
  return width.ceilToDouble() + _inset * 2;
}

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
            _ClipGrid(
              clips: list,
              resting: _resting,
              onPlay: (clip) => unawaited(_play(clip)),
            ),
            const SizedBox(height: AppSpacing.s4),
            const SoundboardVolumeRow(),
          ],
        );
      },
    );
  }
}

/// Tiles in equal columns: three in the popover, and on a touch sheet as many
/// as fit a name like "wrong buzzer" whole. Each row is as tall as its longest
/// name, and past five rows half of the sixth shows that the list scrolls.
class _ClipGrid extends StatelessWidget {
  const _ClipGrid({
    required this.clips,
    required this.resting,
    required this.onPlay,
  });

  final List<api.SoundClip> clips;

  final bool resting;

  final void Function(api.SoundClip clip) onPlay;

  int _columns(BuildContext context, double width) {
    if (!AppTouchTargets.of(context)) return _popoverColumns;
    final fit = (width + _gap) ~/ (_tileMinWidth(context) + _gap);
    return fit < 1 ? 1 : fit;
  }

  /// The height that shows [_wholeRows] rows and the top half of the next.
  double _peekHeight(
    BuildContext context,
    List<List<api.SoundClip>> rows,
    double tileWidth,
  ) {
    if (rows.length <= _wholeRows) return double.infinity;
    final style = DefaultTextStyle.of(context).style.merge(AppText.caption);
    final scaler = MediaQuery.textScalerOf(context);
    double rowHeight(List<api.SoundClip> row) {
      var name = 0.0;
      for (final clip in row) {
        final painter = TextPainter(
          text: TextSpan(text: clip.name, style: style),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: tileWidth - _inset * 2);
        if (painter.height > name) name = painter.height;
        painter.dispose();
      }
      return _inset * 3 + AppSizes.icon20 + name;
    }

    var height = 0.0;
    for (final row in rows.take(_wholeRows)) {
      height += rowHeight(row) + _gap;
    }
    return height + rowHeight(rows[_wholeRows]) / 2;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columns(context, constraints.maxWidth);
        final width = (constraints.maxWidth - _gap * (columns - 1)) / columns;
        final rows = [
          for (var i = 0; i < clips.length; i += columns)
            clips.sublist(i, (i + columns).clamp(0, clips.length)),
        ];
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: _peekHeight(context, rows, width),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: _gap,
              children: [
                for (final row in rows)
                  // Every tile fills the row, so hover, press and focus cover the same height.
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: _gap,
                      children: [
                        for (final clip in row)
                          SizedBox(
                            width: width,
                            child: _ClipTile(
                              key: ValueKey(clip.id),
                              clip: clip,
                              label:
                                  '${clip.name}, ${formatClipLength(clip.durationMs)}',
                              resting: resting,
                              onTap: () => onPlay(clip),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One clip: its emoji, or the music icon for none, over its name. Hover,
/// press and keyboard focus draw as an emoji picker cell does.
class _ClipTile extends StatefulWidget {
  const _ClipTile({
    super.key,
    required this.clip,
    required this.label,
    required this.resting,
    required this.onTap,
  });

  final api.SoundClip clip;

  /// The clip's name and length, for a screen reader.
  final String label;

  /// Resting tiles look and read as disabled but keep their focus, so a
  /// keyboard user is not dropped after every play.
  final bool resting;

  final VoidCallback onTap;

  @override
  State<_ClipTile> createState() => _ClipTileState();
}

class _ClipTileState extends State<_ClipTile> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  Color _fill(AppTokens tokens) {
    if (widget.resting) return Colors.transparent;
    if (_pressed) return tokens.accentSoft;
    return _hovered ? tokens.surfaceSunken : Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final enabled = !widget.resting;
    void activate() {
      if (enabled) widget.onTap();
    }

    final radius = BorderRadius.circular(AppRadii.control);
    final body = Container(
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(color: _fill(tokens), borderRadius: radius),
      foregroundDecoration: _focused
          ? BoxDecoration(
              border: Border.all(color: tokens.focusRing, width: 2),
              borderRadius: radius,
            )
          : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: _inset,
          children: [
            StoredEmoji(widget.clip.emoji, placeholder: AppIcons.music),
            Text(
              widget.clip.name,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      label: widget.label,
      button: true,
      enabled: enabled,
      child: FocusableActionDetector(
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => activate(),
          ),
        },
        child: GestureDetector(
          onTap: activate,
          onTapDown: enabled ? (_) => _press(true) : null,
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          child: ExcludeSemantics(child: body),
        ),
      ),
    );
  }
}
