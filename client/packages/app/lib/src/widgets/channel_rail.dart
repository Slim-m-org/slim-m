// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The left rail: server header, search, direct messages, every channel
/// category, and the signed-in user's footer bar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/channel_order_controller.dart';
import '../providers/dms.dart';
import '../providers/providers.dart';
import '../providers/sync_controller.dart';
import '../providers/sync_failure.dart';
import '../routing/routes.dart';
import 'channel_rail_failure.dart';
import 'channel_rail_frame.dart';
import 'channel_rail_selection_marker.dart';
import 'channel_rail_sections.dart';
import 'command_palette.dart';
import 'context_menu_region.dart';
import 'create_category_sheet.dart';
import 'create_channel_sheet.dart';
import 'personal_account_sections.dart';

/// The channel id in [path], or null when [path] is not a channel route.
///
/// Only the first segment: `/channels/<channel>/m/<message>` is that channel.
String? channelIdInPath(String path) {
  const prefix = '${Routes.channels}/';
  if (!path.startsWith(prefix)) return null;
  final id = path.substring(prefix.length).split('/').first;
  return id.isEmpty ? null : id;
}

/// Whether the channel rail is at its full width, or at
/// [ChannelRail.compactWidth]. `RailDragHandle` flips it at the rail's edge.
///
/// The owner asked for compaction "the way Slack does it": the same rail a
/// little narrower, never a strip of stacked icons. So compact keeps every
/// channel name; only the width and the footer's name line give way.
///
/// In-memory only, like the layout state around it: it resets to full width
/// on every fresh launch.
final channelRailExpandedProvider = StateProvider<bool>((ref) => true);

/// Below this search-field width the Ctrl+K keycaps are dropped; at
/// [ChannelRail.compactWidth] they left room for three letters of Search.
const double _searchHintMinWidth = 200;

/// The route the router puts a channel id into; read here to highlight the
/// selected row, and by [HomeShell] to decide which pane to show.
///
/// Only valid under a `RouteBase.builder` subtree. A dialog, sheet or overlay
/// pushed on the root navigator must read [channelIdInPath] off
/// `GoRouter.of(context).state` instead, or [GoRouterState.of] throws a
/// [GoError], which is an `Error` and so escapes every `on ...Exception` catch.
String? selectedChannelId(BuildContext context) =>
    channelIdInPath(GoRouterState.of(context).uri.path);

class ChannelRail extends ConsumerStatefulWidget {
  const ChannelRail({super.key, this.scrollController, this.markerLayerKey});

  /// Set only by [CompactChannelRailDrawer]: an owned controller it reads
  /// and moves directly once the drawer's first frame lands, to restore the
  /// offset a `Drawer`'s own disposal on close would otherwise reset, and to
  /// scroll the selection into view if that restored offset predates it - a
  /// channel picked while the drawer was closed, say. The docked layouts
  /// pass nothing and keep the scroll view's own implicit controller; they
  /// are never disposed, and snapping a manual scroll back to the selection
  /// there would fight ordinary browsing.
  final ScrollController? scrollController;

  /// Set alongside [scrollController]: [SelectionMarkerLayerState.selectedRect]
  /// is the selected row's position in the scroll view's own content
  /// coordinates, already computed for the marker bar - reused here rather
  /// than a second row-geometry mechanism.
  final GlobalKey<SelectionMarkerLayerState>? markerLayerKey;

  /// The design's measured width at expanded layouts.
  static const double expandedWidth = 248;

  /// Unspecified by the ChatScreen spec (which only covers expanded width);
  /// kept at the app's prior medium-width value.
  static const double mediumWidth = 240;

  /// The compact rail: every channel name still fits beside its glyph at
  /// this width, and [RailUserFooter] drops its name line to keep all three
  /// controls. See [channelRailExpandedProvider].
  static const double compactWidth = 200;

  @override
  ConsumerState<ChannelRail> createState() => _ChannelRailState();
}

class _ChannelRailState extends ConsumerState<ChannelRail> {
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final storeAsync = ref.watch(storeProvider);
    final selected = selectedChannelId(context);
    final me = ref.watch(effectiveMeProvider);
    final canManageChannels =
        me != null && me.permissions.hasPermission(Perm.manageChannels);
    final orderState = ref.watch(channelOrderControllerProvider);
    final orderController = ref.read(channelOrderControllerProvider.notifier);

    return Container(
      color: tokens.surfaceSunken,
      child: Column(
        children: [
          // On every platform, title bar included - 0012's 2026-09-25 addendum.
          const RailHeader(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s12,
              AppRhythm.headingTop,
              AppSpacing.s12,
              AppRhythm.headingBottom,
            ),
            // A real field would take focus and a keyboard; this only opens the
            // palette, so AbsorbPointer stops events and the trigger gets them.
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                key: const Key('rail-search-trigger'),
                onTap: () => openCommandPalette(context),
                child: AbsorbPointer(
                  child: AppInput(
                    // The whole field is the tap target, so it takes the
                    // design's 44pt size rather than its 32pt one on a phone.
                    size: AppTouchTargets.of(context)
                        ? AppInputSize.lg
                        : AppInputSize.sm,
                    placeholder: 'Search',
                    icon: Icon(
                      AppIcons.search,
                      size: AppSizes.icon16,
                      color: tokens.textSecondary,
                    ),
                    // Keycaps only where a keyboard is and the field has room; at compact width the hint crushed the word Search.
                    trailing:
                        AppTouchTargets.of(context) ||
                            constraints.maxWidth < _searchHintMinWidth
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const AppKbd('Ctrl'),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: Text(
                                  '+',
                                  style: AppText.micro.copyWith(
                                    color: tokens.textSecondary,
                                  ),
                                ),
                              ),
                              const AppKbd('K'),
                            ],
                          ),
                    semanticLabel: 'Search channels, members and messages',
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _railBody(
                    storeAsync: storeAsync,
                    orderState: orderState,
                    selected: selected,
                    canManageChannels: canManageChannels,
                    orderController: orderController,
                  ),
                ),
                // Overlaid on the list, not pushed above it: this answers the drag the reader just made, so it attaches to the list a drag happens in rather than displacing every row above to announce it.
                if (orderState.error != null)
                  Positioned(
                    left: AppSpacing.s8,
                    right: AppSpacing.s8,
                    bottom: AppSpacing.s8,
                    child: AppErrorState(
                      message: orderState.error!,
                      onRetry: () => unawaited(orderController.retry()),
                      onDismiss: orderController.dismiss,
                    ),
                  ),
              ],
            ),
          ),
          RailUserFooter(activeChannelId: selected),
        ],
      ),
    );
  }

  Widget _railBody({
    required AsyncValue<MessageStore> storeAsync,
    required ChannelOrderState orderState,
    required String? selected,
    required bool canManageChannels,
    required ChannelOrderController orderController,
  }) {
    return storeAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => RailFailureNotice(
        failure: localStoreRailFailure(e),
        onRetry: () => ref.invalidate(storeProvider),
        onSignInAgain: () => unawaited(SignOutRow.signOut(ref)),
      ),
      data: (store) => StreamBuilder<List<Channel>>(
        // Deduped to what the rail draws; see MessageStore.watchRailChannels.
        stream: store.watchRailChannels(),
        builder: (context, channelSnapshot) {
          return StreamBuilder<List<ChannelCategoryRow>>(
            stream: store.watchCategories(),
            builder: (context, categorySnapshot) {
              final categories =
                  categorySnapshot.data ?? const <ChannelCategoryRow>[];
              final channels = _withPendingOrder(
                channelSnapshot.data ?? const <Channel>[],
                orderState.pendingOrder,
              );
              final nonDm = channels
                  .where((c) => c.kind != dmChannelKind)
                  .toList(growable: false);
              // Only once the store has actually answered with nothing; a stream that has not delivered yet is still loading.
              if (channelSnapshot.hasData && channels.isEmpty) {
                final failure = emptyRailFailure(
                  ref.watch(syncFailureProvider),
                );
                // The stale failure under a live Retry reads as the tap doing nothing.
                final retrying =
                    ref.watch(syncControllerProvider) == SyncStatus.connecting;
                if (failure != null && retrying) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (failure != null) {
                  return RailFailureNotice(
                    failure: failure,
                    onRetry: () => unawaited(
                      ref.read(syncControllerProvider.notifier).start(),
                    ),
                    onSignInAgain: () => unawaited(SignOutRow.signOut(ref)),
                  );
                }
              }
              // Slivers, not one column: the filler sliver gives touch a long-press target under the last row, however short the list is.
              final list = CustomScrollView(
                controller: widget.scrollController,
                slivers: [
                  SliverPadding(
                    // The right inset is load-bearing beyond its own look: RailDragHandle's reach cap assumes a row's own edge sits exactly here.
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.s8,
                      AppRhythm.headingBottom,
                      AppSpacing.s8,
                      0,
                    ),
                    // One box over both sections: the selection marker layer has to span them to slide between them.
                    sliver: SliverToBoxAdapter(
                      child: SelectionMarkerLayer(
                        key: widget.markerLayerKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DirectMessagesSection(
                              channels: channels
                                  .where((c) => c.kind == dmChannelKind)
                                  .toList(),
                              selectedId: selected,
                            ),
                            ChannelCategorySections(
                              channels: nonDm,
                              categories: categories,
                              selectedId: selected,
                              canManage: canManageChannels,
                              onReorder: (groups) =>
                                  unawaited(orderController.reorder(groups)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (canManageChannels)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _RailEmptySpace(),
                    ),
                ],
              );
              if (!canManageChannels) return list;
              // Wraps the whole viewport so the space under the last row is a target too; a row's own menu sits deeper and wins the arena.
              return ContextMenuRegion(
                // False: child is the whole scrollable list, not one row - each row already owns a tab stop, and a second one here rang the whole rail.
                ownsFocusNode: false,
                // Right-click only: a held press here would race the rows; the band under the last row owns the touch long press.
                enableLongPress: false,
                itemsBuilder: railBackgroundMenuItems,
                child: list,
              );
            },
          );
        },
      ),
    );
  }
}

/// Renders [pending] (a reorder this client is waiting on, or has just had
/// refused) over [channels], rather than the plain arrangement the local
/// store still holds - the store is not rewritten until the server confirms
/// it. A channel [pending] does not name (a DM, or one that arrived
/// concurrently) keeps its stored category and position.
List<Channel> _withPendingOrder(
  List<Channel> channels,
  List<api.ChannelOrderGroup>? pending,
) {
  if (pending == null) return channels;
  final byId = {for (final channel in channels) channel.id: channel};
  final named = <String>{};
  final overridden = <Channel>[];
  for (final group in pending) {
    for (var i = 0; i < group.channelIds.length; i++) {
      final original = byId[group.channelIds[i]];
      if (original == null) continue;
      named.add(original.id);
      overridden.add(
        original.repositioned(categoryId: group.categoryId, position: i),
      );
    }
  }
  return [
    ...overridden,
    for (final channel in channels)
      if (!named.contains(channel.id)) channel,
  ];
}

/// The "Create channel... / Create category..." menu of the rail's blank space.
List<Widget> railBackgroundMenuItems(
  BuildContext context,
  VoidCallback close,
) => [
  AppMenuItem(
    label: 'Create channel...',
    leading: AppIcons.add,
    onTap: () {
      close();
      showCreateChannelSheet(context, initialKind: 'text');
    },
  ),
  AppMenuItem(
    label: 'Create category...',
    leading: AppIcons.addCategory,
    onTap: () {
      close();
      showCreateCategorySheet(context);
    },
  ),
];

/// The band under the last row. Its own region, so a held press here opens the
/// menu without any row's hold-then-move drag in the arena.
class _RailEmptySpace extends StatelessWidget {
  const _RailEmptySpace();

  @override
  Widget build(BuildContext context) => const ContextMenuRegion(
    ownsFocusNode: false,
    itemsBuilder: railBackgroundMenuItems,
    // Opaque: an empty box takes no hit, so the press would fall through to the scroll view.
    child: ColoredBox(
      color: Colors.transparent,
      child: SizedBox(height: AppSpacing.s64, width: double.infinity),
    ),
  );
}
