// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Cuts a failing step list down to a short one that still fails the same way.

use crate::script::{Cfg, Step};

async fn still_fails(steps: &[Step], cfg: &Cfg, seed: u64, sig: &str) -> bool {
    let report = crate::world::run(steps, cfg, seed).await;
    report.fatal.is_some_and(|f| f.sig == sig)
}

pub async fn shrink(
    mut steps: Vec<Step>,
    cfg: &Cfg,
    seed: u64,
    sig: &str,
    failed_at: usize,
    budget: usize,
) -> Vec<Step> {
    steps.truncate(failed_at + 1);
    let mut runs = 0;
    let mut chunk = steps.len().div_ceil(2);
    while chunk >= 1 && runs < budget {
        let mut at = 0;
        while at < steps.len() && runs < budget {
            let mut candidate = steps.clone();
            candidate.drain(at..(at + chunk).min(steps.len()));
            runs += 1;
            if !candidate.is_empty() && still_fails(&candidate, cfg, seed, sig).await {
                steps = candidate;
            } else {
                at += chunk;
            }
        }
        if chunk == 1 {
            break;
        }
        chunk = chunk.div_ceil(2);
    }
    steps
}
