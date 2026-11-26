// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The per-call line queues, with no I/O so the limits are plain unit tests.

use std::collections::{HashMap, VecDeque};

use super::Line;
use crate::ids::ChannelId;

#[derive(Default)]
struct Call {
    waiting: VecDeque<Line>,
    speaking: Option<Line>,
}

impl Call {
    fn held_by(&self, line: &Line) -> usize {
        let mine = |l: &&Line| l.user_id == line.user_id;
        self.waiting.iter().filter(mine).count() + self.speaking.iter().filter(mine).count()
    }

    fn size(&self) -> usize {
        self.waiting.len() + usize::from(self.speaking.is_some())
    }
}

pub(super) enum Taken {
    Line(Line),
    Empty,
}

#[derive(Default)]
pub(super) struct Queues(HashMap<ChannelId, Call>);

impl Queues {
    /// Adds `line`, giving how many are ahead of it and whether a worker must be started,
    /// or `None` when the call or the person is at their limit.
    pub(super) fn push(
        &mut self,
        line: Line,
        per_call: usize,
        per_user: usize,
    ) -> Option<(usize, bool)> {
        let call = self.0.entry(line.channel_id).or_default();
        let fresh = call.size() == 0;
        if call.size() >= per_call || call.held_by(&line) >= per_user {
            if fresh {
                self.0.remove(&line.channel_id);
            }
            return None;
        }
        let ahead = call.size();
        call.waiting.push_back(line);
        Some((ahead, fresh))
    }

    /// Starts the next line of `channel`, or forgets the call when none is left.
    pub(super) fn take(&mut self, channel: ChannelId) -> Taken {
        let Some(call) = self.0.get_mut(&channel) else {
            return Taken::Empty;
        };
        match call.waiting.pop_front() {
            Some(line) => {
                call.speaking = Some(line.clone());
                Taken::Line(line)
            }
            None => {
                self.0.remove(&channel);
                Taken::Empty
            }
        }
    }

    pub(super) fn finish(&mut self, channel: ChannelId) {
        if let Some(call) = self.0.get_mut(&channel) {
            call.speaking = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ids::UserId;

    fn line(channel: ChannelId, user: UserId) -> Line {
        Line {
            channel_id: channel,
            user_id: user,
            name: "n".into(),
            text: "t".into(),
        }
    }

    fn ids() -> (ChannelId, UserId, UserId) {
        (
            ChannelId(uuid::Uuid::now_v7()),
            UserId(uuid::Uuid::now_v7()),
            UserId(uuid::Uuid::now_v7()),
        )
    }

    #[test]
    fn the_first_line_starts_a_worker_and_later_ones_queue_behind_it() {
        let (c, a, b) = ids();
        let mut q = Queues::default();
        assert_eq!(q.push(line(c, a), 5, 2), Some((0, true)));
        assert_eq!(q.push(line(c, b), 5, 2), Some((1, false)));
    }

    #[test]
    fn one_person_holds_at_most_their_share_including_the_line_being_spoken() {
        let (c, a, b) = ids();
        let mut q = Queues::default();
        assert!(q.push(line(c, a), 5, 2).is_some());
        assert!(matches!(q.take(c), Taken::Line(_)));
        assert!(q.push(line(c, a), 5, 2).is_some());
        assert_eq!(
            q.push(line(c, a), 5, 2),
            None,
            "one speaking plus one waiting is two"
        );
        assert!(
            q.push(line(c, b), 5, 2).is_some(),
            "someone else is unaffected"
        );
    }

    #[test]
    fn a_call_holds_at_most_its_limit() {
        let (c, ..) = ids();
        let mut q = Queues::default();
        for _ in 0..3 {
            assert!(
                q.push(line(c, UserId(uuid::Uuid::now_v7())), 3, 2)
                    .is_some()
            );
        }
        assert_eq!(q.push(line(c, UserId(uuid::Uuid::now_v7())), 3, 2), None);
    }

    #[test]
    fn calls_do_not_share_a_queue() {
        let (c, a, _) = ids();
        let other = ChannelId(uuid::Uuid::now_v7());
        let mut q = Queues::default();
        assert!(q.push(line(c, a), 1, 1).is_some());
        assert_eq!(q.push(line(other, a), 1, 1), Some((0, true)));
    }

    #[test]
    fn lines_are_taken_in_order_and_an_emptied_call_is_forgotten() {
        let (c, a, b) = ids();
        let mut q = Queues::default();
        q.push(line(c, a), 5, 2);
        q.push(line(c, b), 5, 2);
        let Taken::Line(first) = q.take(c) else {
            panic!()
        };
        assert_eq!(first.user_id, a);
        q.finish(c);
        let Taken::Line(second) = q.take(c) else {
            panic!()
        };
        assert_eq!(second.user_id, b);
        q.finish(c);
        assert!(matches!(q.take(c), Taken::Empty));
        assert_eq!(
            q.push(line(c, a), 5, 2),
            Some((0, true)),
            "a worker starts again"
        );
    }
}
