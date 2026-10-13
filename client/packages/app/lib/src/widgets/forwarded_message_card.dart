// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The container a forwarded message renders inside: who wrote the original,
/// when, where it came from, what it said, and whatever rode along with it.
///
/// Forwarding used to be text. The client composed `Forwarded from <name>`
/// and a markdown quote into the sender's own message, so there was no
/// author to draw, no timestamp but the forward's own, and nowhere to go
/// back to. The origin is a real object now (`ForwardedMessage`), and this
/// is what draws it.
///
/// Where the original came from is resolved here, against this client's own
/// channel cache, and that lookup is the access check rather than a
/// convenience. The server deliberately sends no channel name with a forward
/// - only its id - so a reader is only ever shown a location their own cache
/// can name. A channel this client does not hold is one the reader cannot
/// see, so it shows no location and offers no jump, which is the same answer
/// asking the server would have produced and one round trip cheaper.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'package:go_router/go_router.dart';

import '../providers/channel_by_id_provider.dart';
import '../providers/display_preferences.dart' show watchUse24Hour;
import '../providers/user_profiles.dart';
import 'attachment_gallery.dart';
import 'author_label.dart';
import 'channel_label.dart';
import 'message_jump.dart';
import 'message_row_identity.dart' show formatMessageTime;
import 'user_avatar.dart';

/// The avatar beside a forwarded original, deliberately smaller than a
/// message row's own: this is a quoted author, not the one speaking.
const double _avatarSize = AppAvatarSize.s20;

class ForwardedMessageCard extends ConsumerWidget {
  const ForwardedMessageCard({
    super.key,
    required this.forwarded,
    required this.body,
    required this.attachments,
    required this.currentChannelId,
  });

  final ForwardedMessage forwarded;

  /// The original's own text, already rendered by the caller so markdown,
  /// mentions and custom emoji follow exactly the rules an ordinary message
  /// body does. Null when the original carried no text, which an
  /// attachment-only message legitimately does.
  final Widget? body;

  /// The original's attachments. They are the same content-addressed blobs,
  /// linked to the forwarding message at send time, and they belong inside
  /// this card rather than under it: they are part of what was forwarded,
  /// not something the forwarder attached.
  final List<api.Attachment> attachments;

  /// The channel this forward is being read in, so a jump to an origin that
  /// happens to live here does not needlessly re-navigate.
  final String currentChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (forwarded.removed) return const _RemovedCard();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final use24Hour = watchUse24Hour(ref, context);
    final name = forwarded.authorDisplayName ?? 'Unknown user';
    final time = formatMessageTime(forwarded.createdAt, use24Hour: use24Hour);
    // Live-resolved: isBot/isWebhook are not on the ForwardedMessage snapshot.
    resolveAuthorProfiles(ref, [forwarded.authorId]);
    final authorProfile = ref
        .watch(
          batchProfilesControllerProvider.select(
            (m) => authorResolution(m, forwarded.authorId ?? ''),
          ),
        )
        .profile;
    final origin = ref.watch(channelByIdProvider(forwarded.channelId));
    final originLabel = channelDisplayLabel(origin.valueOrNull);
    // On tap, not on build: eager lookup would demand a router from every surface a message renders on.
    final onJump = originLabel == null
        ? null
        : () => jumpToMessage(
            GoRouter.of(context),
            ref.read,
            currentChannelId: currentChannelId,
            channelId: forwarded.channelId,
            messageId: forwarded.messageId,
          );

    final card = Container(
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      padding: const EdgeInsets.all(AppSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // One sentence over the header's own spans, which read as a pile of fragments; the body below keeps its natural semantics and stays readable.
          Semantics(
            button: onJump != null,
            label: _describe(name, time, originLabel, jumpable: onJump != null),
            child: ExcludeSemantics(
              child: _Header(
                forwarded: forwarded,
                name: name,
                authorProfile: authorProfile,
                time: time,
                originLabel: originLabel,
                jumpable: onJump != null,
              ),
            ),
          ),
          if (body case final body?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: body,
            ),
          if (attachments.isNotEmpty)
            MessageAttachments(attachments: attachments),
        ],
      ),
    );

    if (onJump == null) return card;
    return AppFocusRing(
      radius: AppRadii.control,
      builder: (context, onFocusChange) => InkWell(
        onTap: onJump,
        // AppFocusRing replaces this overlay; see its own doc comment.
        focusColor: Colors.transparent,
        onFocusChange: onFocusChange,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: card,
      ),
    );
  }
}

/// What stands where the snapshot was once its original is deleted or aged
/// out. The forwarder's own note, drawn by the message row, is untouched.
class _RemovedCard extends StatelessWidget {
  const _RemovedCard();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      label: 'Forwarded message. The original message was deleted.',
      child: ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: tokens.surfaceSunken,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.forward, size: 13, color: tokens.textSecondary),
              const SizedBox(width: AppSpacing.s8),
              Flexible(
                child: Text(
                  'Original message was deleted',
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One sentence for a screen reader, in place of the card's own many spans -
/// which read as a pile of fragments otherwise.
String _describe(
  String name,
  String time,
  String? originLabel, {
  required bool jumpable,
}) {
  final where = originLabel == null ? '' : ' in $originLabel';
  final action = jumpable ? ', go to the original' : '';
  return 'Forwarded message from $name$where at $time$action';
}

class _Header extends StatelessWidget {
  const _Header({
    required this.forwarded,
    required this.name,
    required this.authorProfile,
    required this.time,
    required this.originLabel,
    required this.jumpable,
  });

  final ForwardedMessage forwarded;
  final String name;
  final api.UserProfile? authorProfile;
  final String time;
  final String? originLabel;
  final bool jumpable;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Says what the container is, in a word. Without it the box reads as a reply quote, which is a different thing rendered a different way.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.forward, size: 13, color: tokens.textSecondary),
            const SizedBox(width: AppSpacing.s4),
            Text(
              originLabel == null ? 'Forwarded' : 'Forwarded from',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            if (originLabel case final label?) ...[
              const SizedBox(width: AppSpacing.s4),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: jumpable ? tokens.accent : tokens.textSecondary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              if (jumpable) ...[
                const SizedBox(width: AppSpacing.s4),
                Icon(AppIcons.shapeArrow, size: 12, color: tokens.accent),
              ],
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar.known(
              name: name,
              userId: forwarded.authorId,
              avatarUpdatedAt: forwarded.authorAvatarUpdatedAt,
              size: _avatarSize,
            ),
            const SizedBox(width: AppSpacing.s8),
            Flexible(
              child: AuthorNameLine(
                name: name,
                profile: authorProfile,
                style: AppText.caption.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.s8),
            Text(
              time,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ],
    );
  }
}
