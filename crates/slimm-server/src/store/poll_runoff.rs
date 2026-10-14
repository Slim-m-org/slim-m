// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Instant-runoff counting for ranked polls, as a pure function so the rule
//! is testable without a database.
//!
//! Each round counts every ballot for its highest-ranked option still in
//! the running. An option with more than half of the ballots still counting
//! wins. Otherwise every option tied for the fewest votes is dropped at
//! once, so the result never depends on an arbitrary tie-break; when that
//! would drop every remaining option, the poll is a tie and has no winner.
//! A ballot that ranks none of the remaining options stops counting.

/// The rounds of an instant-runoff count and its outcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Runoff {
    /// Each round's `(position, votes)` for the options still running at
    /// its start, in option order. Empty when nobody has voted.
    pub rounds: Vec<Vec<(i64, i64)>>,
    /// The winning position, or `None` for no votes or a tie.
    pub winner: Option<i64>,
}

/// Counts `ballots` (each a ranking of positions, best first) over the
/// poll's `options` positions.
pub fn instant_runoff(options: &[i64], ballots: &[Vec<i64>]) -> Runoff {
    let mut running: Vec<i64> = options.to_vec();
    let mut rounds = Vec::new();
    if ballots.is_empty() {
        return Runoff {
            rounds,
            winner: None,
        };
    }
    loop {
        let counts: Vec<(i64, i64)> = running
            .iter()
            .map(|&position| {
                let votes = ballots
                    .iter()
                    .filter(|ballot| first_running(ballot, &running) == Some(position))
                    .count() as i64;
                (position, votes)
            })
            .collect();
        let counting: i64 = counts.iter().map(|&(_, votes)| votes).sum();
        let top = counts.iter().copied().max_by_key(|&(_, votes)| votes);
        rounds.push(counts.clone());

        if let Some((position, votes)) = top
            && votes * 2 > counting
        {
            return Runoff {
                rounds,
                winner: Some(position),
            };
        }
        let fewest = counts.iter().map(|&(_, votes)| votes).min().unwrap_or(0);
        let survivors: Vec<i64> = counts
            .iter()
            .filter(|&&(_, votes)| votes > fewest)
            .map(|&(position, _)| position)
            .collect();
        if survivors.is_empty() {
            return Runoff {
                rounds,
                winner: None,
            };
        }
        running = survivors;
    }
}

fn first_running(ballot: &[i64], running: &[i64]) -> Option<i64> {
    ballot
        .iter()
        .copied()
        .find(|position| running.contains(position))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ballots(spec: &[(&[i64], usize)]) -> Vec<Vec<i64>> {
        spec.iter()
            .flat_map(|(ranking, n)| std::iter::repeat_n(ranking.to_vec(), *n))
            .collect()
    }

    #[test]
    fn nobody_voting_has_no_rounds_and_no_winner() {
        let runoff = instant_runoff(&[0, 1, 2], &[]);
        assert!(runoff.rounds.is_empty());
        assert_eq!(runoff.winner, None);
    }

    #[test]
    fn an_outright_majority_wins_in_the_first_round() {
        let runoff = instant_runoff(&[0, 1, 2], &ballots(&[(&[1, 0], 3), (&[0], 1), (&[2], 1)]));
        assert_eq!(runoff.rounds, vec![vec![(0, 1), (1, 3), (2, 1)]]);
        assert_eq!(runoff.winner, Some(1));
    }

    #[test]
    fn second_choices_transfer_when_the_last_option_drops() {
        let runoff = instant_runoff(
            &[0, 1, 2],
            &ballots(&[(&[0], 4), (&[1, 2], 3), (&[2, 1], 2)]),
        );
        assert_eq!(
            runoff.rounds,
            vec![vec![(0, 4), (1, 3), (2, 2)], vec![(0, 4), (1, 5)]]
        );
        assert_eq!(runoff.winner, Some(1));
    }

    #[test]
    fn options_tied_for_last_drop_together() {
        let runoff = instant_runoff(
            &[0, 1, 2, 3],
            &ballots(&[(&[0], 3), (&[1], 2), (&[2, 1], 1), (&[3, 1], 1)]),
        );
        assert_eq!(runoff.rounds.len(), 2);
        assert_eq!(runoff.rounds[1], vec![(0, 3), (1, 4)]);
        assert_eq!(runoff.winner, Some(1));
    }

    #[test]
    fn an_even_split_between_the_last_two_is_a_tie() {
        let runoff = instant_runoff(&[0, 1], &ballots(&[(&[0], 2), (&[1], 2)]));
        assert_eq!(runoff.rounds, vec![vec![(0, 2), (1, 2)]]);
        assert_eq!(runoff.winner, None);
    }

    #[test]
    fn an_exhausted_ballot_stops_counting_toward_the_majority() {
        let runoff = instant_runoff(&[0, 1, 2], &ballots(&[(&[0], 2), (&[1], 2), (&[2], 1)]));
        assert_eq!(runoff.rounds[1], vec![(0, 2), (1, 2)]);
        assert_eq!(runoff.winner, None);
    }

    #[test]
    fn an_option_nobody_ranked_drops_in_the_first_round() {
        let runoff = instant_runoff(&[0, 1, 2], &ballots(&[(&[0, 1], 1), (&[1, 0], 1)]));
        assert_eq!(runoff.rounds[0], vec![(0, 1), (1, 1), (2, 0)]);
        assert_eq!(runoff.winner, None);
    }
}
