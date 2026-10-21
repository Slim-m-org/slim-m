// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Setting a store's answer against the oracle's prediction.

use slimm_server::ids::CanvasObjectId;
use slimm_server::store::{PlaceError, Placement, SubmitOpError, SubmittedOp};

use crate::oracle::{Fail, Good, Pred};
use crate::script::{Act, Step};
use crate::world::{Check, World, v};

pub struct Got {
    pub affected: i64,
    pub fresh: bool,
    pub seq: i64,
    pub touched: Vec<CanvasObjectId>,
}

fn act_name(act: &Act) -> &'static str {
    match act {
        Act::Place { .. } => "place",
        Act::Move { .. } => "move",
        Act::Edit { .. } => "edit",
        Act::Reorder { .. } => "reorder",
        Act::Remove { .. } => "remove",
        Act::Clear { .. } => "clear",
        Act::Restore { .. } => "restore",
        Act::Lock { .. } => "lock",
        Act::SetCap(_) => "set_cap",
        Act::SetMod { .. } => "set_mod",
        Act::Restart => "restart",
        Act::Retry { .. } => "retry",
        Act::AgeAndSweep => "sweep",
    }
}

fn fail_name(f: &Fail) -> String {
    format!("{f:?}").split('(').next().unwrap_or("").to_owned()
}

pub fn map_submit(r: Result<SubmittedOp, SubmitOpError>) -> Result<Got, Fail> {
    match r {
        Ok(op) => Ok(Got {
            affected: op.affected,
            fresh: op.fresh,
            seq: op.seq,
            touched: op.touched_ids,
        }),
        Err(SubmitOpError::NotFound) => Err(Fail::NotFound),
        Err(SubmitOpError::NotAuthorized) => Err(Fail::NotAuthorized),
        Err(SubmitOpError::ChannelFull) => Err(Fail::ChannelFull),
        Err(SubmitOpError::OutOfBounds) => Err(Fail::OutOfBounds),
        Err(SubmitOpError::NotEditable) => Err(Fail::NotEditable),
        Err(SubmitOpError::Locked) => Err(Fail::Locked),
        Err(SubmitOpError::Internal(e)) => Err(Fail::Internal(format!("{e:#}"))),
    }
}

pub fn map_place(r: Result<Placement, PlaceError>) -> Result<Got, Fail> {
    match r {
        Ok(p) => Ok(Got {
            affected: 1,
            fresh: p.fresh,
            seq: p.object.seq.0,
            touched: vec![p.object.id],
        }),
        Err(PlaceError::Removed) => Err(Fail::Removed),
        Err(PlaceError::OutOfBounds) => Err(Fail::OutOfBounds),
        Err(PlaceError::ChannelFull) => Err(Fail::ChannelFull),
        Err(other) => Err(Fail::Internal(format!("{other:?}"))),
    }
}

impl World {
    pub fn compare(&mut self, i: usize, step: &Step, pred: &Pred, got: Result<Got, Fail>) -> Check {
        let name = act_name(&step.act);
        let outcome = match (pred, &got) {
            (Ok(p), Ok(_)) if !p.fresh => "replayed".to_owned(),
            (Ok(_), Ok(g)) if g.affected == 0 => "noop".to_owned(),
            (Ok(_), Ok(_)) => "applied".to_owned(),
            (Err(f), _) => fail_name(f),
            (Ok(_), Err(g)) => fail_name(g),
        };
        *self.stats.entry(format!("{name}:{outcome}")).or_default() += 1;
        let detail =
            |extra: String| format!("{name} by w{} at step {}: {extra}", step.writer, step.label);
        match (pred, got) {
            (Err(p), Err(g)) if *p == g => Ok(()),
            (Err(p), Err(g)) => Err(v(
                format!("{name}:expected_{}_got_{}", fail_name(p), fail_name(&g)),
                i,
                detail(format!("expected {p:?}, store said {g:?}")),
            )),
            (Ok(p), Err(g)) => Err(v(
                format!("{name}:expected_ok_got_{}", fail_name(&g)),
                i,
                detail(format!("expected success {p:?}, store said {g:?}")),
            )),
            (Err(p), Ok(g)) => Err(v(
                format!("{name}:expected_{}_got_ok", fail_name(p)),
                i,
                detail(format!(
                    "expected {p:?}, store accepted affected={} seq={}",
                    g.affected, g.seq
                )),
            )),
            (Ok(p), Ok(g)) => self.compare_ok(i, name, p, &g).map_err(|mut viol| {
                viol.detail = detail(viol.detail);
                viol
            }),
        }
    }

    fn compare_ok(&mut self, i: usize, name: &str, p: &Good, g: &Got) -> Check {
        if p.fresh != g.fresh {
            return Err(v(
                format!("{name}:fresh_flag"),
                i,
                format!("expected fresh={}, got {}", p.fresh, g.fresh),
            ));
        }
        if p.seq != g.seq {
            return Err(v(
                format!("{name}:seq"),
                i,
                format!("expected seq {}, got {}", p.seq, g.seq),
            ));
        }
        if p.affected != g.affected {
            let viol = v(
                format!("{name}:affected"),
                i,
                format!("expected affected {}, got {}", p.affected, g.affected),
            );
            if p.fresh || name == "place" {
                return Err(viol);
            }
            self.soft
                .push(v(format!("retry_{name}:affected_drift"), i, viol.detail));
        }
        if p.fresh {
            let mut want: Vec<CanvasObjectId> = p.touched.iter().map(|l| self.obj_ids[l]).collect();
            let mut have = g.touched.clone();
            want.sort();
            have.sort();
            if want != have {
                return Err(v(
                    format!("{name}:touched"),
                    i,
                    format!("expected touched {want:?}, got {have:?}"),
                ));
            }
        }
        Ok(())
    }
}
