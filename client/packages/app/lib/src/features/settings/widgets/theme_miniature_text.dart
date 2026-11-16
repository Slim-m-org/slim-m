// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The miniature's text details: the hero at the top of Appearance and the
/// editor's draft, both real text in the theme's own tokens.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Below this the hero's channel list narrows and the picture gets shorter.
const _heroNarrow = 480.0;

/// The draft shows its channel list from this width.
const _draftRailFrom = 400.0;

/// The theme in use, as a short stretch of a real channel.
class ThemeMiniatureHero extends StatelessWidget {
  const ThemeMiniatureHero({super.key, required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final narrow = box.maxWidth < _heroNarrow;
      return SizedBox(
        height: narrow ? 152 : 176,
        child: ColoredBox(
          color: tokens.surfaceBase,
          child: ClipRect(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ChannelList(
                  tokens: tokens,
                  width: narrow ? 104 : 152,
                  channels: const ['general', 'design', 'music'],
                ),
                Expanded(child: _heroChat(narrow: narrow)),
              ],
            ),
          ),
        ),
      );
    },
  );

  /// Narrow, one whole message fits: the one with the link.
  Widget _heroChat({required bool narrow}) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AppSpacing.s12,
                children: [
                  _Message(
                    tokens: tokens,
                    who: 'Ada',
                    time: '9:41',
                    text: 'The new theme is up.',
                    link: 'Release notes',
                  ),
                  if (!narrow)
                    _Message(
                      tokens: tokens,
                      who: 'Grace',
                      time: '9:42',
                      text: 'Reads well from here.',
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        _Composer(tokens: tokens),
      ],
    ),
  );
}

/// Every token somewhere: the editor's preview of the theme being made.
class ThemeMiniatureDraft extends StatelessWidget {
  const ThemeMiniatureDraft({
    super.key,
    required this.tokens,
    this.strip = false,
  });

  final AppTokens tokens;

  /// A phone's short strip: no channel list, the stripe or the samples.
  final bool strip;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final rail = !strip && box.maxWidth >= _draftRailFrom;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceBase,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border.all(color: tokens.borderSubtle),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.card - 1),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rail)
                  _ChannelList(
                    tokens: tokens,
                    width: 104,
                    channels: const ['general', 'music', 'builds'],
                    muted: 'builds',
                  ),
                Expanded(child: _draftChat()),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _draftChat() {
    Widget inset(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
      child: child,
    );
    final link = Text(
      'Link to the build',
      style: AppText.ui.copyWith(color: tokens.accent),
    );
    final danger = Text(
      'Delete failed',
      style: AppText.ui.copyWith(color: tokens.dangerText),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s12,
        children: [
          inset(
            _Message(
              tokens: tokens,
              who: 'Ren',
              time: '9:41',
              text: 'Pine at dusk is up. Have a look at the new theme.',
            ),
          ),
          if (!strip) _stripe(),
          inset(
            Wrap(
              spacing: AppSpacing.s12,
              runSpacing: AppSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [link, danger, if (strip) _warn()],
            ),
          ),
          if (!strip)
            inset(Align(alignment: Alignment.centerLeft, child: _warn())),
          inset(_Composer(tokens: tokens, sendLabel: 'Send')),
          if (!strip) ...[inset(_error()), inset(_focus())],
        ],
      ),
    );
  }

  /// Hangs past the column by 8 so its text lines up with the others.
  Widget _stripe() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.stripe,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s8),
        child: _Message(
          tokens: tokens,
          who: 'Kai',
          text: 'Reads well. The links are a bit dim.',
          quiet: true,
        ),
      ),
    ),
  );

  Widget _warn() => DecoratedBox(
    decoration: BoxDecoration(
      color: tokens.warnSoft,
      borderRadius: BorderRadius.circular(AppRadii.control),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: 2,
      ),
      child: Text(
        'Low battery',
        style: AppText.caption.copyWith(color: tokens.warnText),
      ),
    ),
  );

  Widget _error() => _Sample(
    border: Border.all(color: tokens.dangerBorder),
    child: Text(
      'Could not send. Try again.',
      style: AppText.caption.copyWith(color: tokens.dangerText),
    ),
  );

  Widget _focus() => _Sample(
    border: Border.all(color: tokens.focusRing, width: 2),
    child: Text(
      'Focused control',
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    ),
  );
}

class _Sample extends StatelessWidget {
  const _Sample({required this.border, required this.child});

  final BoxBorder border;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(AppRadii.control),
      border: border,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
      child: child,
    ),
  );
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.tokens,
    required this.width,
    required this.channels,
    this.muted,
  });

  final AppTokens tokens;
  final double width;

  /// The first is the selected channel.
  final List<String> channels;
  final String? muted;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border(right: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 2,
          children: [
            for (final (i, name) in channels.indexed)
              _channel(name, selected: i == 0, muted: name == muted),
          ],
        ),
      ),
    ),
  );

  Widget _channel(String name, {required bool selected, required bool muted}) {
    final colour = selected
        ? tokens.textPrimary
        : muted
        ? tokens.textDisabled
        : tokens.textSecondary;
    return SizedBox(
      height: AppSizes.rowPointer,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? tokens.accentSoft : null,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Stack(
          children: [
            if (selected)
              Positioned(
                left: 0,
                top: 6,
                bottom: 6,
                width: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.accent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Row(
                spacing: AppSpacing.s4,
                children: [
                  Icon(AppIcons.hash, size: AppSizes.icon16, color: colour),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui.copyWith(color: colour),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.tokens,
    required this.who,
    required this.text,
    this.time,
    this.link,
    this.quiet = false,
  });

  final AppTokens tokens;
  final String who;
  final String text;
  final String? time;

  /// Secondary text, so the draft shows that token on a line too.
  final bool quiet;

  /// Accent text after the message, the one link a miniature shows.
  final String? link;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 2,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        spacing: AppSpacing.s8,
        children: [
          Text(
            who,
            maxLines: 1,
            style: AppText.ui.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          if (time case final time?)
            Text(
              time,
              style: AppText.micro.copyWith(
                fontFamily: AppFonts.mono,
                color: tokens.textSecondary,
              ),
            ),
        ],
      ),
      Text.rich(
        TextSpan(
          text: text,
          children: [
            if (link case final link?)
              TextSpan(
                text: ' $link',
                style: TextStyle(color: tokens.accent),
              ),
          ],
        ),
        style: AppText.ui.copyWith(
          color: quiet ? tokens.textSecondary : tokens.textPrimary,
        ),
      ),
    ],
  );
}

class _Composer extends StatelessWidget {
  const _Composer({required this.tokens, this.sendLabel});

  final AppTokens tokens;

  /// A labelled send button; null draws the icon alone.
  final String? sendLabel;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: tokens.surfaceRaised,
      borderRadius: BorderRadius.circular(AppRadii.control),
      border: Border.all(color: tokens.borderStrong),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s12,
        AppSpacing.s4,
        AppSpacing.s4,
        AppSpacing.s4,
      ),
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          Expanded(
            child: Text(
              'Message #general',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(color: tokens.textDisabled),
            ),
          ),
          _send(),
        ],
      ),
    ),
  );

  Widget _send() {
    final label = sendLabel;
    return Container(
      height: AppSizes.controlSm,
      constraints: const BoxConstraints(minWidth: AppSizes.controlSm),
      padding: label == null
          ? null
          : const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.accentFill,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: tokens.accentRing, width: 2),
      ),
      child: label == null
          ? Icon(AppIcons.send, size: AppSizes.icon16, color: tokens.accentOn)
          : Text(
              label,
              style: AppText.caption.copyWith(
                color: tokens.accentOn,
                fontWeight: AppWeights.medium,
              ),
            ),
    );
  }
}
