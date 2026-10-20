// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The reference model: what a canvas should look like after each step,
//! written from the documented rules rather than from the store's queries.

use std::collections::{HashMap, HashSet};

use slimm_server::store::{MAX_OBJECT_EXTENT, WORLD_LIMIT};

use crate::script::{Act, Bounds, Fence, Kind, Step};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fail {
    NotFound,
    NotAuthorized,
    ChannelFull,
    OutOfBounds,
    NotEditable,
    Locked,
    Removed,
    Internal(String),
}

pub type Pred = Result<Good, Fail>;

#[derive(Debug, Default)]
pub struct Good {
    pub affected: i64,
    pub fresh: bool,
    pub seq: i64,
    pub touched: Vec<u32>,
    pub changed: bool,
}

#[derive(Clone, Debug)]
pub struct Obj {
    pub kind: Kind,
    pub author: usize,
    pub seq: i64,
    pub b: Bounds,
    pub z: i64,
    pub props: String,
    pub alive: bool,
    pub dead_by: Option<u32>,
    pub locked: bool,
}

pub struct OpRec {
    pub seq: i64,
    pub kind: &'static str,
    pub actor: usize,
    pub touched: Vec<u32>,
    pub affected: i64,
}

pub struct Oracle {
    pub objs: HashMap<u32, Obj>,
    pub ops: HashMap<u32, OpRec>,
    pub latest: i64,
    pub cap: i64,
    pub audit: i64,
    pub mods: Vec<bool>,
}

pub fn valid(b: Bounds) -> bool {
    let (x, y, w, h) = b;
    [x, y, w, h].iter().all(|v| v.is_finite())
        && w >= 0.0
        && h >= 0.0
        && w <= MAX_OBJECT_EXTENT
        && h <= MAX_OBJECT_EXTENT
        && x >= -WORLD_LIMIT
        && y >= -WORLD_LIMIT
        && x + w <= WORLD_LIMIT
        && y + h <= WORLD_LIMIT
}

pub fn props_for(kind: Kind, text: u8) -> String {
    let pad = if text == 3 {
        format!(r#","pad":"{}""#, "x".repeat(3400))
    } else {
        String::new()
    };
    match kind {
        Kind::Note => format!(r#"{{"color":"annotation","text":"note {text}"{pad}}}"#),
        Kind::Stroke => {
            format!(r#"{{"color":"annotation","points":[0.0,0.0,1.0,1.0],"width":3.0{pad}}}"#)
        }
        Kind::Shape => format!(r#"{{"color":"annotation","primitive":"rect"{pad}}}"#),
        Kind::Image => format!(r#"{{"content_type":"image/png"{pad}}}"#),
    }
}

fn ok(affected: i64, seq: i64, touched: Vec<u32>, changed: bool) -> Pred {
    Ok(Good {
        affected,
        fresh: true,
        seq,
        touched,
        changed,
    })
}

fn fail(f: Fail) -> Pred {
    Err(f)
}

impl Oracle {
    pub fn new(mods: Vec<bool>, cap: i64) -> Self {
        Self {
            objs: HashMap::new(),
            ops: HashMap::new(),
            latest: 0,
            cap,
            audit: 0,
            mods,
        }
    }

    pub fn live(&self) -> i64 {
        self.objs.values().filter(|o| o.alive).count() as i64
    }

    fn row(&mut self, affected: i64, touched: Vec<u32>) -> Pred {
        if affected == 0 {
            return ok(0, self.latest, Vec::new(), false);
        }
        self.latest += 1;
        ok(affected, self.latest, touched, true)
    }

    fn replay(rec: &OpRec) -> Pred {
        Ok(Good {
            affected: rec.affected,
            fresh: false,
            seq: rec.seq,
            ..Good::default()
        })
    }

    fn record(&mut self, step: &Step, kind: &'static str, pred: &Pred) {
        let Ok(res) = pred else { return };
        if !res.changed {
            return;
        }
        let rec = OpRec {
            seq: res.seq,
            kind,
            actor: step.writer,
            touched: res.touched.clone(),
            affected: res.affected,
        };
        if matches!(kind, "remove" | "clear" | "restore") {
            self.audit += res.touched.len() as i64;
        }
        self.ops.insert(step.label, rec);
    }

    pub fn predict(&mut self, step: &Step) -> Pred {
        if let Some(rec) = self.ops.get(&step.label) {
            return Self::replay(rec);
        }
        let actor = step.writer;
        let moderator = self.mods[actor];
        match &step.act {
            Act::Place { kind, b, text } => self.place(step, *kind, *b, *text),
            Act::Move { obj, b } => self.guarded(step, "move", *obj, moderator, |o| {
                if !valid(*b) {
                    return Err(Fail::OutOfBounds);
                }
                o.b = *b;
                Ok(())
            }),
            Act::Reorder { obj, z } => self.guarded(step, "reorder", *obj, moderator, |o| {
                o.z = *z;
                Ok(())
            }),
            Act::Edit { obj, text } => self.edit(step, *obj, *text),
            Act::Remove { objs } => self.remove(step, objs),
            Act::Clear {
                fence,
                kinds,
                author,
            } => self.clear(step, *fence, kinds, *author),
            Act::Restore { op } => self.restore(step, *op),
            Act::Lock { .. }
            | Act::SetCap(_)
            | Act::SetMod { .. }
            | Act::Retry { .. }
            | Act::Restart
            | Act::AgeAndSweep => unreachable!("handled by the world"),
        }
    }

    fn place(&mut self, step: &Step, kind: Kind, b: Bounds, text: u8) -> Pred {
        if !valid(b) {
            return fail(Fail::OutOfBounds);
        }
        if let Some(existing) = self.objs.get(&step.label) {
            if !existing.alive {
                return fail(Fail::Removed);
            }
            let seq = existing.seq;
            return Ok(Good {
                affected: 1,
                fresh: false,
                seq,
                ..Good::default()
            });
        }
        if self.live() >= self.cap {
            return fail(Fail::ChannelFull);
        }
        self.latest += 1;
        let obj = Obj {
            kind,
            author: step.writer,
            seq: self.latest,
            b,
            z: self.latest,
            props: props_for(kind, text),
            alive: true,
            dead_by: None,
            locked: false,
        };
        self.objs.insert(step.label, obj);
        ok(1, self.latest, vec![step.label], true)
    }

    fn guarded(
        &mut self,
        step: &Step,
        kind: &'static str,
        obj: u32,
        moderator: bool,
        change: impl FnOnce(&mut Obj) -> Result<(), Fail>,
    ) -> Pred {
        let Some(o) = self.objs.get_mut(&obj) else {
            return fail(Fail::NotFound);
        };
        if !moderator && o.author != step.writer {
            return fail(Fail::NotAuthorized);
        }
        if o.locked {
            return fail(Fail::Locked);
        }
        if !o.alive {
            return ok(0, self.latest, Vec::new(), false);
        }
        let mut next = o.clone();
        if let Err(f) = change(&mut next) {
            return fail(f);
        }
        *o = next;
        let pred = self.row(1, vec![obj]);
        self.record(step, kind, &pred);
        pred
    }

    fn edit(&mut self, step: &Step, obj: u32, text: u8) -> Pred {
        let moderator = self.mods[step.writer];
        let Some(o) = self.objs.get_mut(&obj) else {
            return fail(Fail::NotFound);
        };
        if !moderator && o.author != step.writer {
            return fail(Fail::NotAuthorized);
        }
        if o.kind != Kind::Note {
            return fail(Fail::NotEditable);
        }
        if o.locked {
            return fail(Fail::Locked);
        }
        let props = props_for(Kind::Note, text);
        if !o.alive || o.props == props {
            return ok(0, self.latest, Vec::new(), false);
        }
        o.props = props;
        let pred = self.row(1, vec![obj]);
        self.record(step, "edit", &pred);
        pred
    }

    fn remove(&mut self, step: &Step, objs: &[u32]) -> Pred {
        let moderator = self.mods[step.writer];
        for id in objs {
            let Some(o) = self.objs.get(id) else {
                return fail(Fail::NotFound);
            };
            if !moderator && o.author != step.writer {
                return fail(Fail::NotAuthorized);
            }
        }
        let mut seen = HashSet::new();
        let mut touched = Vec::new();
        for id in objs {
            let o = &self.objs[id];
            if o.alive && !o.locked && seen.insert(*id) {
                touched.push(*id);
            }
        }
        for id in &touched {
            let o = self.objs.get_mut(id).expect("checked above");
            o.alive = false;
            o.dead_by = Some(step.label);
        }
        let pred = self.row(touched.len() as i64, touched);
        self.record(step, "remove", &pred);
        pred
    }

    fn clear(&mut self, step: &Step, fence: Fence, kinds: &[Kind], author: Option<usize>) -> Pred {
        if !self.mods[step.writer] {
            return fail(Fail::NotAuthorized);
        }
        let bound = match fence {
            Fence::Head => self.latest,
            Fence::Behind(n) => (self.latest - n).max(0),
            Fence::Ahead(n) => self.latest + n,
            Fence::Zero => 0,
        };
        let mut touched: Vec<u32> = self
            .objs
            .iter()
            .filter(|(_, o)| o.alive && o.seq <= bound)
            .filter(|(_, o)| kinds.is_empty() || kinds.contains(&o.kind))
            .filter(|(_, o)| author.is_none_or(|a| o.author == a))
            .map(|(label, _)| *label)
            .collect();
        touched.sort_unstable();
        for id in &touched {
            let o = self.objs.get_mut(id).expect("collected above");
            o.alive = false;
            o.dead_by = Some(step.label);
        }
        let pred = self.row(touched.len() as i64, touched);
        self.record(step, "clear", &pred);
        pred
    }

    fn restore(&mut self, step: &Step, target: u32) -> Pred {
        let moderator = self.mods[step.writer];
        let Some(rec) = self.ops.get(&target) else {
            return fail(Fail::NotFound);
        };
        if !matches!(rec.kind, "remove" | "clear") {
            return fail(Fail::NotFound);
        }
        if !moderator && (rec.kind == "clear" || rec.actor != step.writer) {
            return fail(Fail::NotAuthorized);
        }
        let candidates = rec.touched.clone();
        if !moderator
            && candidates
                .iter()
                .any(|c| self.objs[c].author != step.writer)
        {
            return fail(Fail::NotAuthorized);
        }
        let dead: Vec<u32> = candidates
            .into_iter()
            .filter(|c| !self.objs[c].alive && self.objs[c].dead_by == Some(target))
            .collect();
        if !dead.is_empty() && self.live() + dead.len() as i64 > self.cap {
            return fail(Fail::ChannelFull);
        }
        for id in &dead {
            let o = self.objs.get_mut(id).expect("candidate");
            o.alive = true;
            o.dead_by = None;
        }
        let pred = self.row(dead.len() as i64, dead);
        self.record(step, "restore", &pred);
        pred
    }
}
