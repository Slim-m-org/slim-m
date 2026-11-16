// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The role ladder: a caller manages only roles, and moderates only members, strictly below their
//! own highest role. See `docs/decisions/0092-server-hardening-review-answers.md` (2026-11-16).

use std::cmp::Ordering;

use axum::http::StatusCode;

use super::AppState;
use super::error::ApiError;
use crate::ids::UserId;
use crate::store::Role;

/// The stable `code` every ladder refusal carries, so a client never reads the sentence.
pub(crate) const LADDER_CODE: &str = "role_hierarchy";

/// The refusal for a role at or above the caller's highest role.
const ROLE_NOT_BELOW_YOU: &str = "you can only manage roles below your highest role";

/// The refusal for a member whose highest role is above the caller's, or the Space owner.
const MEMBER_NOT_BELOW_YOU: &str = "you can only act on members below your highest role";

/// The refusal for a peer, which the client also says in plain words.
pub(crate) const EQUAL_RANK_REFUSED: &str = "you cannot act on someone of equal rank";

/// The code a hand grant or revoke of a bot-held role is refused with.
pub(crate) const BOT_ROLE_CODE: &str = "role_follows_bot";

const ROLE_FOLLOWS_BOTS: &str =
    "this role follows its bot and cannot be granted or taken away by hand";

/// Where one caller stands, read once per request.
pub(in crate::http) struct Ladder {
    caller: UserId,
    owner: Option<UserId>,
    /// `None` holds no role, which ranks below every role, `@everyone` being under them all.
    top: Option<i64>,
}

impl Ladder {
    pub(in crate::http) async fn of(state: &AppState, caller: UserId) -> Result<Self, ApiError> {
        Ok(Self {
            caller,
            owner: state.store.space_owner().await?,
            top: top_position(state, caller).await?,
        })
    }

    /// The Space owner stands above every role.
    pub(in crate::http) fn exempt(&self) -> bool {
        self.owner == Some(self.caller)
    }

    /// Refuses unless a role at `position` sits strictly below the caller's highest role.
    pub(in crate::http) fn reach_role(&self, position: i64) -> Result<(), ApiError> {
        if self.exempt() || self.top.is_some_and(|top| position < top) {
            Ok(())
        } else {
            Err(refusal(ROLE_NOT_BELOW_YOU))
        }
    }

    /// Refuses unless `target` is not the owner and ranks strictly below the caller.
    pub(in crate::http) async fn reach_member(
        &self,
        state: &AppState,
        target: UserId,
    ) -> Result<(), ApiError> {
        let target_top = top_position(state, target).await?;
        member_reach(
            self.exempt(),
            self.owner == Some(target),
            self.top,
            target_top,
        )
        .map_err(refusal)
    }

    /// [`Self::reach_member`], except that an act a caller aims at themselves needs no rank.
    pub(in crate::http) async fn reach_other(
        &self,
        state: &AppState,
        target: UserId,
    ) -> Result<(), ApiError> {
        if target == self.caller {
            Ok(())
        } else {
            self.reach_member(state, target).await
        }
    }

    /// Refuses giving the owner a role or taking one away, unless the owner does it.
    pub(in crate::http) fn spare_owner(&self, target: UserId) -> Result<(), ApiError> {
        if self.owner == Some(target) && !self.exempt() {
            Err(refusal(MEMBER_NOT_BELOW_YOU))
        } else {
            Ok(())
        }
    }
}

/// Refuses a hand grant or revoke of a role that bots hold by being bots.
pub(in crate::http) fn hand_assignable(role: &Role) -> Result<(), ApiError> {
    if role.managed_bot_id.is_some() || role.is_bots_role {
        Err(ApiError::Coded {
            status: StatusCode::CONFLICT,
            message: ROLE_FOLLOWS_BOTS,
            code: BOT_ROLE_CODE,
        })
    } else {
        Ok(())
    }
}

/// Where `user` stands: their highest role's position, `None` when they hold no role.
pub(in crate::http) async fn top_position(
    state: &AppState,
    user: UserId,
) -> Result<Option<i64>, ApiError> {
    Ok(state.store.highest_role_position(user).await?)
}

fn refusal(message: &'static str) -> ApiError {
    ApiError::Coded {
        status: StatusCode::FORBIDDEN,
        message,
        code: LADDER_CODE,
    }
}

fn member_reach(
    caller_is_owner: bool,
    target_is_owner: bool,
    caller_top: Option<i64>,
    target_top: Option<i64>,
) -> Result<(), &'static str> {
    if caller_is_owner {
        return Ok(());
    }
    if target_is_owner {
        return Err(MEMBER_NOT_BELOW_YOU);
    }
    match caller_top.cmp(&target_top) {
        Ordering::Greater => Ok(()),
        Ordering::Equal => Err(EQUAL_RANK_REFUSED),
        Ordering::Less => Err(MEMBER_NOT_BELOW_YOU),
    }
}

#[cfg(test)]
mod tests {
    use super::{EQUAL_RANK_REFUSED, MEMBER_NOT_BELOW_YOU, member_reach};

    #[test]
    fn a_member_strictly_below_is_in_reach() {
        assert_eq!(member_reach(false, false, Some(5), Some(4)), Ok(()));
    }

    /// Any role, even one still at the bottom position, ranks above holding none.
    #[test]
    fn a_member_with_no_role_ranks_below_every_role() {
        assert_eq!(member_reach(false, false, Some(0), None), Ok(()));
        assert_eq!(
            member_reach(false, false, None, Some(0)),
            Err(MEMBER_NOT_BELOW_YOU)
        );
    }

    #[test]
    fn a_peer_is_refused_as_equal_rank_and_a_senior_as_out_of_reach() {
        assert_eq!(
            member_reach(false, false, Some(5), Some(5)),
            Err(EQUAL_RANK_REFUSED)
        );
        assert_eq!(
            member_reach(false, false, None, None),
            Err(EQUAL_RANK_REFUSED)
        );
        assert_eq!(
            member_reach(false, false, Some(5), Some(6)),
            Err(MEMBER_NOT_BELOW_YOU)
        );
    }

    #[test]
    fn nobody_reaches_the_owner_and_the_owner_reaches_everyone() {
        assert_eq!(
            member_reach(false, true, Some(100), None),
            Err(MEMBER_NOT_BELOW_YOU)
        );
        assert_eq!(member_reach(true, false, None, Some(100)), Ok(()));
    }
}
