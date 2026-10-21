// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who gets woken for a message, and why each exclusion is there.
//!
//! Its own module rather than three steps inside [`super::deliver::deliver`]'s
//! fire-and-forget task: this is the whole authorization decision on the push
//! path, and a task that reports to nothing but the process log cannot be
//! tested. `tests/blocking_reach.rs` drives it directly.

use std::collections::HashSet;

use crate::ids::{ChannelId, UserId};
use crate::notification_schedule::degrade_for_off_hours;
use crate::notifications::NotificationPreference;
use crate::permissions::Permissions;
use crate::presence::PresenceTracker;
use crate::store::{NotificationChoice, Store, ThreadParent};

use super::mention_grammar::{mentioned_role_names, mentioned_usernames};
use crate::http::code_fences::prose_outside_code;

/// The reserved mention naming every candidate viewer, never a real
/// username: `validate_username` (`http/auth.rs`) refuses to register it for
/// exactly this reason, so `@everyone` can never collide with an account.
const EVERYONE_MENTION: &str = "everyone";

/// The reserved mention naming every candidate viewer who is currently
/// connected - the same reservation, and the same refusal, as
/// [`EVERYONE_MENTION`].
const HERE_MENTION: &str = "here";

/// Who should be woken for `content` in `channel_id`, written by `author_id`.
///
/// The set is built from who could receive a push at all, then filtered by view
/// permission, rather than evaluating permissions for every live user and then
/// asking which of them have a device. Both orders give the same recipients, but
/// this one costs a single indexed query on a deployment where nobody has
/// registered for push, instead of a full permission evaluation per user on
/// every message sent. The view check itself is not an optimization to skip: a
/// recipient who cannot see the channel must never be told a message landed in
/// it.
///
/// The author is dropped, and so is anybody who has blocked them. Push is the
/// one surface a client-side block filter cannot reach - the notification is on
/// the device before any filter runs - and a phone that buzzes for a message the
/// app then hides is worse than no filtering, since it reports exactly when the
/// blocked person spoke. It stays a view choice rather than a moderation action:
/// the message is delivered to everybody else and the author is never told.
///
/// When `channel_id` is a thread's own channel, [`narrow_for_thread`] further
/// cuts this down to the thread's own audience; every other channel passes
/// through unchanged. [`narrow_for_notification_preference`] runs last, over
/// whatever survived both of the above: each recipient's own
/// [`NotificationPreference`] is the final word on whether this particular
/// message is worth waking them for, the same "read where the audience is
/// computed" choke point blocking already uses above, not a filter a client
/// applies after a device has already buzzed.
///
/// `presence` answers `@here`'s "currently connected" question; see
/// [`resolved_mentions`].
///
/// [`crate::mentions::mentioned_viewers`] is the sibling entry point that
/// calls [`resolved_mentions`] directly rather than through this function:
/// this one's `candidates` starts from push-registered accounts, which is
/// the right pool for "who to wake" but the wrong one for "who this message
/// mentions" - a mention is true of an account whether or not it has ever
/// registered a device.
pub async fn message_recipients(
    store: &Store,
    channel_id: ChannelId,
    author_id: UserId,
    content: &str,
    presence: &PresenceTracker,
) -> anyhow::Result<Vec<UserId>> {
    let (recipients, _mentioned) =
        message_audience(store, channel_id, author_id, content, presence, None).await?;
    Ok(recipients)
}

/// [`message_recipients`] plus who among everyone the message mentions, so a mention can be
/// pushed as one.
pub(crate) async fn message_audience(
    store: &Store,
    channel_id: ChannelId,
    author_id: UserId,
    content: &str,
    presence: &PresenceTracker,
    reply_ping: Option<UserId>,
) -> anyhow::Result<(Vec<UserId>, HashSet<UserId>)> {
    // Push registrations first, permissions second; see the note above.
    let candidates = store.users_with_push_devices().await?;
    let blockers = store.blockers_of(author_id).await?;
    let candidates: Vec<UserId> = candidates
        .into_iter()
        .filter(|user_id| *user_id != author_id && !blockers.contains(user_id))
        .collect();
    let viewers = store.viewers_among(channel_id, &candidates).await?;
    let mut mentioned =
        resolved_mentions(store, channel_id, author_id, content, &viewers, presence).await?;
    // A reply's ping was already checked against the channel at send; it still needs a device and no block.
    mentioned.extend(reply_ping.filter(|pinged| viewers.contains(pinged)));
    // Resolved once: both steps below ask the same "is this a thread, and whose" question.
    let parent = store.thread_parent(channel_id).await?;
    let viewers =
        narrow_for_thread(store, channel_id, parent.as_ref(), &mentioned, viewers).await?;
    let scope = Scope {
        channel_id,
        parent_channel_id: parent.map(|parent| parent.parent_channel_id),
    };
    let automated = store.is_automated_author(author_id).await?;
    let audience = Audience {
        mentioned: &mentioned,
        automated,
    };
    let recipients =
        narrow_for_notification_preference(store, scope, author_id, audience, viewers).await?;
    Ok((recipients, mentioned))
}

/// The distinct accounts a message's mentions resolve to - shared by
/// [`narrow_for_thread`] and [`narrow_for_notification_preference`] so a
/// message that is both a thread reply and has mentions only pays for the
/// resolution once.
///
/// [`EVERYONE_MENTION`] and [`HERE_MENTION`] are pulled out of the ordinary
/// `@username` set before it goes to [`Store::user_ids_for_usernames`] -
/// neither is ever a real account, so asking the username table about them
/// would only ever answer "no such user". Each expands against `viewers`
/// (already the candidates this message's channel and blocking already
/// allow) rather than every account in the deployment, and only once the
/// author is confirmed to hold [`Permissions::MENTION_EVERYONE`] in
/// `channel_id` - checked here, at the one place a mass mention turns into an
/// actual wake, rather than by refusing the send: a caller without the bit
/// can still type the word, it just pings nobody extra, the same forgiving
/// shape an ordinary `@nobody` already has. `@everyone` expands to every
/// viewer; `@here` narrows that to whoever `presence` reports connected right
/// now, which is what distinguishes the two words at all.
///
/// `@[Role Name]` mentions (recognised by [`mentioned_role_names`], a
/// separate bracketed grammar from the plain `@name` one above - see that
/// function's own doc for why) resolve the same forgiving way: each name is
/// looked up with [`Store::roles_for_names`], and a match expands to
/// [`Store::members_with_role`] intersected with `viewers`, but only when
/// that role's own [`crate::store::Role::mentionable`] flag is set, or the
/// author holds [`Permissions::MENTION_EVERYONE`] - the same override that
/// already lets that bit bypass `@everyone`/`@here`. Deliberately not a
/// second permission bit: a role a manager already opted in to being
/// mentioned needs no further gate, and one they did not stays quiet for
/// everybody except the same override that already ignores every other
/// mention gate in this function.
/// What kinds of mention `content` makes, read without touching the store, so
/// a caller can skip loading the whole channel audience for a message that
/// only names people (or nobody).
pub(crate) struct MentionKinds {
    pub names: bool,
    pub mass_or_role: bool,
}

pub(crate) fn mention_kinds(content: &str) -> MentionKinds {
    let prose = prose_outside_code(content);
    let mut names = mentioned_usernames(&prose);
    let mass = names.remove(EVERYONE_MENTION) | names.remove(HERE_MENTION);
    MentionKinds {
        names: !names.is_empty(),
        mass_or_role: mass || !mentioned_role_names(&prose).is_empty(),
    }
}

pub(crate) async fn resolved_mentions(
    store: &Store,
    channel_id: ChannelId,
    author_id: UserId,
    content: &str,
    viewers: &[UserId],
    presence: &PresenceTracker,
) -> anyhow::Result<HashSet<UserId>> {
    let prose = prose_outside_code(content);
    let content = prose.as_str();
    let mut names = mentioned_usernames(content);
    let mentions_everyone = names.remove(EVERYONE_MENTION);
    let mentions_here = names.remove(HERE_MENTION);
    let role_names: Vec<String> = mentioned_role_names(content).into_iter().collect();

    let mut resolved: HashSet<UserId> = if names.is_empty() {
        HashSet::new()
    } else {
        let names: Vec<String> = names.into_iter().collect();
        store
            .user_ids_for_usernames(&names)
            .await?
            .into_iter()
            .collect()
    };

    // Shared by both overrides below, so paid for once, not once per mention kind.
    let mention_everyone_held = if mentions_everyone || mentions_here || !role_names.is_empty() {
        store
            .has_permission(author_id, channel_id, Permissions::MENTION_EVERYONE)
            .await?
    } else {
        false
    };

    if (mentions_everyone || mentions_here) && mention_everyone_held {
        if mentions_everyone {
            resolved.extend(viewers.iter().copied());
        } else {
            resolved.extend(
                viewers
                    .iter()
                    .copied()
                    .filter(|user_id| presence.is_connected(*user_id)),
            );
        }
    }

    if !role_names.is_empty() {
        let viewers: HashSet<UserId> = viewers.iter().copied().collect();
        for role in store.roles_for_names(&role_names).await? {
            if !(role.mentionable || mention_everyone_held) {
                continue;
            }
            let members = store.members_with_role(role.id).await?;
            resolved.extend(members.into_iter().filter(|id| viewers.contains(id)));
        }
    }

    Ok(resolved)
}

/// The channel a message landed in, plus the parent channel it hangs off when
/// that channel is a thread's own - what every per-channel preference below has
/// to read, since a thread is a channel row of its own but not a place anybody
/// set their preferences on.
#[derive(Debug, Clone, Copy)]
struct Scope {
    channel_id: ChannelId,
    parent_channel_id: Option<ChannelId>,
}

/// Narrows `viewers` to a thread's own audience, for a reply into a thread's
/// own channel; every other channel is returned unchanged.
///
/// `viewers` already answers "who may see this", by the same
/// [`Store::permission_channel`] resolution to the parent every other check
/// uses - correct for authorization, and untouched here. What is wrong for a
/// thread is treating that whole parent-channel audience as who should be
/// *woken* by one reply in what may be a two-person side conversation. The
/// audience is [`Store::thread_participants`] (the parent message's author
/// plus everyone who has posted in the thread) unioned with `mentioned`
/// (already resolved by the caller), each still intersected with `viewers` so
/// this can only ever remove somebody from the set already permission-checked
/// above, never add a view nobody granted.
async fn narrow_for_thread(
    store: &Store,
    channel_id: ChannelId,
    parent: Option<&ThreadParent>,
    mentioned: &HashSet<UserId>,
    viewers: Vec<UserId>,
) -> anyhow::Result<Vec<UserId>> {
    let Some(parent) = parent else {
        return Ok(viewers);
    };
    let mut audience = store
        .thread_participants(channel_id, parent.parent_message_id)
        .await?;
    audience.extend(mentioned.iter().copied());
    Ok(viewers
        .into_iter()
        .filter(|user_id| audience.contains(user_id))
        .collect())
}

/// Narrows `viewers` by each recipient's own *effective* [`NotificationPreference`]
/// for `scope`: that recipient's own per-channel override
/// (`store/channel_notification_prefs.rs`) if they have set one for this
/// channel, else the one they set on the parent channel when this is a
/// thread, else their account-wide default. [`NotificationPreference::Nothing`]
/// drops them unconditionally, including from a DM; [`NotificationPreference::Mentions`]
/// keeps them only if `mentioned` names them or `channel_id` resolves to a DM
/// (see [`Store::channel_notifies_as_dm`] for why a DM counts - somebody
/// messaging this account there is addressing them directly, the same as a
/// mention); and [`NotificationPreference::Everything`] passes everyone
/// through unfiltered, which is what every account already got before either
/// preference existed. A channel override always wins over the account
/// default, in both directions: a `nothing`/`mentions` override silences a
/// channel an `everything` default would have let through, and a `mentions`
/// override still wakes a mentioned recipient whose account default is
/// `nothing`.
///
/// The notification schedule (`store/notification_schedule.rs`) runs last,
/// over whatever this resolved: a recipient whose schedule reads the current
/// instant as off hours (`Schedule::evaluate`, in their own IANA time zone)
/// has their effective preference degraded by
/// [`degrade_for_off_hours`] before the match above runs, unless this
/// message's author or channel is on that recipient's own off-hours
/// allow-list. A recipient with no schedule configured at all is untouched -
/// see `store/notification_schedule.rs`'s own doc comment for why that is a
/// distinct state from a schedule with every day empty.
///
/// A channel the recipient can read but not post in (a feed, an announcement
/// channel) wakes them only for mentions unless they chose otherwise for that
/// channel: [`read_only_default`] has the rule.
async fn narrow_for_notification_preference(
    store: &Store,
    scope: Scope,
    author_id: UserId,
    audience: Audience<'_>,
    viewers: Vec<UserId>,
) -> anyhow::Result<Vec<UserId>> {
    let Audience {
        mentioned,
        automated,
    } = audience;
    if viewers.is_empty() {
        return Ok(viewers);
    }
    let Scope {
        channel_id,
        parent_channel_id,
    } = scope;
    let choices = store
        .channel_notification_choices(channel_id, parent_channel_id, &viewers)
        .await?;
    let senders: HashSet<UserId> = store
        .holders_among(channel_id, &viewers, Permissions::SEND_MESSAGES)
        .await?
        .into_iter()
        .collect();
    let is_dm = store.channel_notifies_as_dm(channel_id).await?;
    let schedules = store.notification_schedules_for_users(&viewers).await?;
    let channel_allowed = store
        .viewers_allowing_channel_off_hours(&viewers, channel_id, parent_channel_id)
        .await?;
    let author_allowed = store
        .viewers_allowing_author_off_hours(&viewers, author_id)
        .await?;
    let now_ms = crate::store::now_ms();
    Ok(viewers
        .into_iter()
        .filter(|user_id| {
            let choice = choices.get(user_id).copied().unwrap_or(NotificationChoice {
                preference: NotificationPreference::default(),
                overridden: false,
            });
            let mut preference = read_only_default(choice, senders.contains(user_id), automated);
            if let Some(schedule) = schedules.get(user_id) {
                preference = degrade_for_off_hours(
                    preference,
                    schedule.evaluate(now_ms),
                    channel_allowed.contains(user_id),
                    author_allowed.contains(user_id),
                );
            }
            match preference {
                NotificationPreference::Everything => true,
                NotificationPreference::Nothing => false,
                NotificationPreference::Mentions => is_dm || mentioned.contains(user_id),
            }
        })
        .collect())
}

/// What the message itself says about who it is for.
#[derive(Clone, Copy)]
struct Audience<'a> {
    mentioned: &'a HashSet<UserId>,
    /// Written by a bot or a webhook rather than a person.
    automated: bool,
}

/// The preference once posting rights and authorship are known: without a channel override, "everything" becomes "mentions" for a reader who cannot post and for any reader of a bot or webhook post.
/// An explicit choice for the channel always stands.
fn read_only_default(
    choice: NotificationChoice,
    can_send: bool,
    automated: bool,
) -> NotificationPreference {
    match (choice.preference, choice.overridden) {
        (NotificationPreference::Everything, false) if !can_send || automated => {
            NotificationPreference::Mentions
        }
        (preference, _) => preference,
    }
}
