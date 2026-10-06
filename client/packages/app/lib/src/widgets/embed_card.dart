// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card a webhook's or a bot's embed renders as. See decision 0030.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../external_link.dart';
import '../format.dart';
import '../providers/attachment_preview_quality.dart';
import '../providers/display_preferences.dart';
import '../providers/link_preview.dart';
import '../providers/media_preferences.dart';
import 'attachment_reveal.dart';
import 'attachment_view.dart' show kInlineImageMax;
import 'image_decode.dart';
import 'text_link.dart';

Color _accentColor(api.EmbedAccent accent) => switch (accent) {
  api.EmbedAccent.red => AppEmbedAccents.red,
  api.EmbedAccent.orange => AppEmbedAccents.orange,
  api.EmbedAccent.yellow => AppEmbedAccents.yellow,
  api.EmbedAccent.green => AppEmbedAccents.green,
  api.EmbedAccent.blue => AppEmbedAccents.blue,
  api.EmbedAccent.purple => AppEmbedAccents.purple,
};

/// One card per embed, below a message's own text.
class EmbedList extends StatelessWidget {
  const EmbedList({super.key, required this.embeds});

  final List<api.Embed> embeds;

  @override
  Widget build(BuildContext context) {
    if (embeds.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final embed in embeds)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: EmbedCard(embed: embed),
          ),
      ],
    );
  }
}

class EmbedCard extends StatelessWidget {
  const EmbedCard({super.key, required this.embed});

  final api.Embed embed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final accent = embed.accent;
    // A per-side Border colour cannot share a borderRadius, so the accent is a separate stripe.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: accent == null ? 0 : 4,
                  child: accent == null
                      ? null
                      : ColoredBox(
                          key: const Key('embed-accent-stripe'),
                          color: _accentColor(accent),
                        ),
                ),
                Expanded(
                  child: _EmbedBody(embed: embed, tokens: tokens),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmbedBody extends StatelessWidget {
  const _EmbedBody({required this.embed, required this.tokens});

  final api.Embed embed;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (embed.authorName case final authorName?)
            _EmbedAuthorRow(name: authorName, url: embed.authorUrl),
          if (embed.title case final title?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: _EmbedTitle(title: title, url: embed.url),
            ),
          if (embed.description case final description?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Text(
                description,
                style: AppText.body.copyWith(color: tokens.textPrimary),
              ),
            ),
          if (embed.fields.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: _EmbedFields(fields: embed.fields),
            ),
          if (embed.imageToken case final token?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: _EmbedImage(token: token),
            )
          else if (embed.thumbnailToken case final token?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: _EmbedImage(token: token),
            ),
          if (embed.footerText != null || embed.timestamp != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: _EmbedFooter(
                text: embed.footerText,
                timestamp: embed.timestamp,
              ),
            ),
        ],
      ),
    );
  }
}

class _EmbedAuthorRow extends StatelessWidget {
  const _EmbedAuthorRow({required this.name, this.url});

  final String name;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final row = Text(
      name,
      style: AppText.caption.copyWith(
        color: tokens.textSecondary,
        fontWeight: AppWeights.semi,
      ),
    );
    final authorUrl = url;
    if (authorUrl == null) return row;
    return TextLink(
      onOpen: () => unawaited(openExternalHttpUrl(authorUrl)),
      child: row,
    );
  }
}

class _EmbedTitle extends StatelessWidget {
  const _EmbedTitle({required this.title, this.url});

  final String title;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final text = Text(
      title,
      style: AppText.body.copyWith(
        fontWeight: AppWeights.semi,
        color: url == null ? tokens.textPrimary : tokens.accent,
      ),
    );
    final targetUrl = url;
    if (targetUrl == null) return text;
    return TextLink(
      onOpen: () => unawaited(openExternalHttpUrl(targetUrl)),
      child: text,
    );
  }
}

/// Inline fields wrap several to a row; a non-inline one takes the full
/// width, which forces the [Wrap] onto its own line for it.
class _EmbedFields extends StatelessWidget {
  const _EmbedFields({required this.fields});

  final List<api.EmbedField> fields;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Wrap(
      spacing: AppSpacing.s16,
      runSpacing: AppSpacing.s8,
      children: [
        for (final field in fields)
          SizedBox(
            width: field.inline ? 160 : double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  field.name,
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                Text(
                  field.value,
                  style: AppText.caption.copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EmbedFooter extends ConsumerWidget {
  const _EmbedFooter({this.text, this.timestamp});

  final String? text;
  final int? timestamp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final parts = [
      if (text case final text?) text,
      if (timestamp case final at?)
        formatDateTime(at, use24Hour: watchUse24Hour(ref, context)),
    ];
    return Text(
      parts.join(' · '),
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
  }
}

/// The same proxied-image plumbing `LinkPreviewCard` uses: an opaque token
/// redeemed through the server, never the caller's upstream URL.
class _EmbedImage extends ConsumerStatefulWidget {
  const _EmbedImage({required this.token});

  final String token;

  @override
  ConsumerState<_EmbedImage> createState() => _EmbedImageState();
}

class _EmbedImageState extends ConsumerState<_EmbedImage> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final autoDownload = ref.watch(mediaAutoDownloadControllerProvider);
    if (autoDownload == MediaAutoDownload.manual && !_revealed) {
      return AttachmentRevealTile(
        icon: AppIcons.image,
        line: 'Tap to load image',
        caption: 'Embed image',
        maxEdge: kInlineImageMax,
        onReveal: () => setState(() => _revealed = true),
      );
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final previewScale = ref
        .watch(attachmentPreviewQualityControllerProvider)
        .decodeScale;
    final decodeWidth = decodeEdge(
      context,
      kInlineImageMax,
      scale: previewScale,
    );
    final bytesAsync = ref.watch(linkPreviewImageBytesProvider(widget.token));
    final bytes = bytesAsync.valueOrNull;
    if (bytes == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: kInlineImageMax,
          maxHeight: kInlineImageMax,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: decodeWidth,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
