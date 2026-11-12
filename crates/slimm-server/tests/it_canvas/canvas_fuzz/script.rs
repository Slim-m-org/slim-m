// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Seeded generation of canvas steps as plain data, so a failing sequence can
//! be replayed and shrunk without the generator's random stream.

use std::collections::HashMap;

pub type Bounds = (f64, f64, f64, f64);

/// Object labels at or above this never name a placed object.
pub const PHANTOM_BASE: u32 = 1_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Stroke,
    Shape,
    Note,
    Image,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Stroke => "stroke",
            Kind::Shape => "shape",
            Kind::Note => "note",
            Kind::Image => "image",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum Fence {
    Head,
    Behind(i64),
    Ahead(i64),
    Zero,
}

#[derive(Clone, Debug)]
pub enum Act {
    Place {
        kind: Kind,
        b: Bounds,
        text: u8,
    },
    Move {
        obj: u32,
        b: Bounds,
    },
    Edit {
        obj: u32,
        text: u8,
    },
    Reorder {
        obj: u32,
        z: i64,
    },
    Remove {
        objs: Vec<u32>,
    },
    Clear {
        fence: Fence,
        kinds: Vec<Kind>,
        author: Option<usize>,
    },
    Restore {
        op: u32,
    },
    Lock {
        obj: u32,
        on: bool,
    },
    SetCap(i64),
    SetMod {
        who: usize,
        on: bool,
    },
    Retry {
        of: u32,
    },
    Restart,
    AgeAndSweep,
}

#[derive(Clone, Debug)]
pub struct Step {
    pub label: u32,
    pub writer: usize,
    pub act: Act,
}

/// Generator families a run can switch off to dig past a finding already made.
#[derive(Clone, Default)]
pub struct Skip(Vec<String>);

impl Skip {
    pub fn parse(list: &str) -> Self {
        Self(list.split(',').map(|s| s.trim().to_owned()).collect())
    }

    pub fn has(&self, family: &str) -> bool {
        self.0.iter().any(|s| s == family)
    }
}

#[derive(Clone)]
pub struct Cfg {
    pub writers: usize,
    pub steps: usize,
    pub cap: i64,
    pub prelude: usize,
    pub skip: Skip,
}

impl Cfg {
    pub fn for_seed(seed: u64, steps: usize, skip: &Skip) -> Self {
        let bulk = seed % 16 == 5 && !skip.has("bulk");
        Self {
            writers: 2 + (seed % 3) as usize,
            steps: if bulk { 1100 + steps / 2 } else { steps },
            cap: if seed.is_multiple_of(3) && !bulk {
                100
            } else {
                20_000
            },
            prelude: if bulk { 1100 } else { 0 },
            skip: skip.clone(),
        }
    }
}

pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ 0xD1B5_4A32_D192_ED03)
    }

    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    pub fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }

    pub fn chance(&mut self, pct: u64) -> bool {
        self.below(100) < pct
    }

    pub fn range(&mut self, lo: i64, hi: i64) -> i64 {
        lo + self.below((hi - lo + 1) as u64) as i64
    }

    pub fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

const WORLD: f64 = 5_000_000.0;
const EXTENT: f64 = 8_192.0;

fn edge_bounds(rng: &mut Rng, subnormal: bool) -> Bounds {
    match rng.below(20) {
        0 => (0.0, 0.0, 0.0, 0.0),
        1 => (10.0, 10.0, -1.0, 5.0),
        2 => (10.0, 10.0, 5.0, -0.5),
        3 => (f64::NAN, 0.0, 5.0, 5.0),
        4 => (0.0, f64::INFINITY, 5.0, 5.0),
        5 => (0.0, 0.0, f64::NEG_INFINITY, 5.0),
        6 => (0.0, 0.0, EXTENT, EXTENT),
        7 => (0.0, 0.0, EXTENT + 1.0, 10.0),
        8 => (WORLD - 10.0, 0.0, 10.0, 10.0),
        9 => (WORLD - 10.0, 0.0, 10.5, 10.0),
        10 => (-WORLD, -WORLD, 1.0, 1.0),
        11 => (-WORLD - 1.0, 0.0, 1.0, 1.0),
        12 => (1e300, 0.0, 1.0, 1.0),
        13 => (0.0, 0.0, 5.0, f64::MAX),
        14 if subnormal => (-0.0, 0.1 + 0.2, f64::MIN_POSITIVE, 1e-300),
        14 => (-0.0, 0.1 + 0.2, 1e-9, 1e-12),
        15 => (WORLD - EXTENT, WORLD - EXTENT, EXTENT, EXTENT),
        16 => (0.0, WORLD - 10.0, 10.0, 10.5),
        17 => (0.0, WORLD - 10.0, 10.0, 10.0),
        18 => (0.0, -WORLD - 1.0, 1.0, 1.0),
        _ => (0.0, -WORLD, 1.0, 1.0),
    }
}

pub fn bounds(rng: &mut Rng, skip: &Skip) -> Bounds {
    if !skip.has("degenerate") && rng.chance(22) {
        return edge_bounds(rng, !skip.has("subnormal"));
    }
    let x = rng.range(-3000, 3000) as f64 + rng.unit();
    let y = rng.range(-3000, 3000) as f64 + rng.unit();
    (
        x,
        y,
        1.0 + rng.below(500) as f64,
        1.0 + rng.below(500) as f64,
    )
}

#[derive(Clone, Copy)]
enum Family {
    Place,
    Move,
    Remove,
    Clear,
    Restore,
    Edit,
    Reorder,
    Lock,
    Retry,
    SetCap,
    SetMod,
    Restart,
    Sweep,
}

#[derive(Default)]
struct Pool {
    placed: Vec<u32>,
    authors: HashMap<u32, usize>,
    removals: Vec<u32>,
    every: Vec<u32>,
    sweeps: u32,
}

fn pick_kind(rng: &mut Rng, skip: &Skip) -> Kind {
    match rng.below(100) {
        0..=44 => Kind::Stroke,
        45..=64 => Kind::Shape,
        65..=89 => Kind::Note,
        _ if skip.has("image") => Kind::Stroke,
        _ => Kind::Image,
    }
}

impl Pool {
    fn obj(&self, rng: &mut Rng) -> u32 {
        if self.placed.is_empty() || rng.chance(7) {
            return PHANTOM_BASE + rng.below(3) as u32;
        }
        let recent = rng.chance(50);
        let n = self.placed.len();
        let i = if recent {
            n - 1 - rng.below(n.min(8) as u64) as usize
        } else {
            rng.below(n as u64) as usize
        };
        self.placed[i]
    }

    fn family(&self, rng: &mut Rng, cfg: &Cfg) -> Family {
        let heavy = cfg.cap < 1000;
        let table = [
            (if heavy { 70 } else { 28 }, Family::Place),
            (14, Family::Move),
            (if heavy { 5 } else { 9 }, Family::Remove),
            (if heavy { 2 } else { 4 }, Family::Clear),
            (if heavy { 10 } else { 7 }, Family::Restore),
            (7, Family::Edit),
            (5, Family::Reorder),
            (5, Family::Lock),
            (if cfg.skip.has("retry") { 0 } else { 8 }, Family::Retry),
            (
                if cfg.skip.has("cap_lower") { 0 } else { 1 },
                Family::SetCap,
            ),
            (if cfg.skip.has("mods") { 0 } else { 1 }, Family::SetMod),
            (if cfg.skip.has("restart") { 0 } else { 1 }, Family::Restart),
            (
                if cfg.skip.has("sweep") || self.sweeps >= 3 {
                    0
                } else {
                    1
                },
                Family::Sweep,
            ),
        ];
        let total: u64 = table.iter().map(|(w, _)| *w as u64).sum();
        let mut roll = rng.below(total);
        for (weight, family) in table {
            if roll < weight as u64 {
                return family;
            }
            roll -= weight as u64;
        }
        Family::Place
    }

    fn act(&mut self, rng: &mut Rng, cfg: &Cfg) -> Act {
        let family = if self.placed.is_empty() {
            Family::Place
        } else {
            self.family(rng, cfg)
        };
        match family {
            Family::Place => Act::Place {
                kind: pick_kind(rng, &cfg.skip),
                b: bounds(rng, &cfg.skip),
                text: rng.below(4) as u8,
            },
            Family::Move => Act::Move {
                obj: self.obj(rng),
                b: bounds(rng, &cfg.skip),
            },
            Family::Edit => Act::Edit {
                obj: self.obj(rng),
                text: rng.below(4) as u8,
            },
            Family::Reorder => Act::Reorder {
                obj: self.obj(rng),
                z: rng.range(-1000, 1_000_000),
            },
            Family::Remove => self.remove(rng, cfg),
            Family::Clear => self.clear(rng, cfg),
            Family::Restore => Act::Restore {
                op: self.restore_target(rng),
            },
            Family::Lock if cfg.skip.has("lock") => Act::Move {
                obj: self.obj(rng),
                b: bounds(rng, &cfg.skip),
            },
            Family::Lock => Act::Lock {
                obj: self.obj(rng),
                on: rng.chance(65),
            },
            Family::Retry if self.every.is_empty() => Act::SetCap(cfg.cap),
            Family::Retry => Act::Retry {
                of: self.every[rng.below(self.every.len() as u64) as usize],
            },
            Family::SetCap => Act::SetCap(rng.range(100, 160)),
            Family::SetMod => Act::SetMod {
                who: rng.below(cfg.writers as u64) as usize,
                on: rng.chance(50),
            },
            Family::Restart => Act::Restart,
            Family::Sweep => {
                self.sweeps += 1;
                Act::AgeAndSweep
            }
        }
    }

    fn bulk_place(&mut self, rng: &mut Rng) -> Act {
        let x = rng.range(-3000, 3000) as f64;
        let y = rng.range(-3000, 3000) as f64;
        Act::Place {
            kind: pick_kind(rng, &Skip::default()),
            b: (
                x,
                y,
                1.0 + rng.below(300) as f64,
                1.0 + rng.below(300) as f64,
            ),
            text: if rng.chance(50) {
                3
            } else {
                rng.below(3) as u8
            },
        }
    }

    fn remove(&mut self, rng: &mut Rng, cfg: &Cfg) -> Act {
        let mut objs: Vec<u32> = (0..1 + rng.below(4)).map(|_| self.obj(rng)).collect();
        if cfg.skip.has("dup_ids") {
            let mut seen = Vec::new();
            objs.retain(|o| {
                let fresh = !seen.contains(o);
                seen.push(*o);
                fresh
            });
        } else if rng.chance(5) {
            objs.push(objs[0]);
        }
        Act::Remove { objs }
    }

    fn clear(&mut self, rng: &mut Rng, cfg: &Cfg) -> Act {
        let fence = match rng.below(100) {
            0..=59 => Fence::Head,
            60..=84 => Fence::Behind(rng.range(1, 20)),
            85..=92 => Fence::Ahead(rng.range(1, 50)),
            _ => Fence::Zero,
        };
        let kinds = if rng.chance(70) {
            Vec::new()
        } else {
            let all = [Kind::Stroke, Kind::Shape, Kind::Note, Kind::Image];
            (0..1 + rng.below(2))
                .map(|_| all[rng.below(4) as usize])
                .collect()
        };
        let author = rng
            .chance(20)
            .then(|| rng.below(cfg.writers as u64) as usize);
        Act::Clear {
            fence,
            kinds,
            author,
        }
    }

    fn restore_target(&self, rng: &mut Rng) -> u32 {
        if rng.chance(8) || (self.removals.is_empty() && self.every.is_empty()) {
            return PHANTOM_BASE + 50 + rng.below(3) as u32;
        }
        if rng.chance(12) && !self.every.is_empty() {
            return self.every[rng.below(self.every.len() as u64) as usize];
        }
        if self.removals.is_empty() {
            return PHANTOM_BASE + 50;
        }
        self.removals[rng.below(self.removals.len() as u64) as usize]
    }

    fn writer(&self, act: &Act, rng: &mut Rng, writers: usize) -> usize {
        let owner = match act {
            Act::Move { obj, .. }
            | Act::Edit { obj, .. }
            | Act::Reorder { obj, .. }
            | Act::Lock { obj, .. } => self.authors.get(obj).copied(),
            Act::Remove { objs } => objs.first().and_then(|o| self.authors.get(o).copied()),
            Act::Clear { .. } | Act::Restore { .. } if rng.chance(55) => Some(0),
            _ => None,
        };
        match owner {
            Some(w) if rng.chance(70) => w,
            _ => rng.below(writers as u64) as usize,
        }
    }

    fn note(&mut self, label: u32, act: &Act, writer: usize) {
        match act {
            Act::Place { .. } => {
                self.placed.push(label);
                self.authors.insert(label, writer);
                self.every.push(label);
            }
            Act::Remove { .. } | Act::Clear { .. } => {
                self.removals.push(label);
                self.every.push(label);
            }
            Act::Move { .. }
            | Act::Edit { .. }
            | Act::Reorder { .. }
            | Act::Restore { .. }
            | Act::Lock { .. } => self.every.push(label),
            Act::SetCap(_)
            | Act::SetMod { .. }
            | Act::Retry { .. }
            | Act::Restart
            | Act::AgeAndSweep => {}
        }
    }
}

pub fn generate(seed: u64, cfg: &Cfg) -> Vec<Step> {
    let mut rng = Rng::new(seed);
    let mut pool = Pool::default();
    let mut steps = Vec::with_capacity(cfg.steps);
    for label in 0..cfg.steps as u32 {
        let act = if (label as usize) < cfg.prelude {
            pool.bulk_place(&mut rng)
        } else {
            pool.act(&mut rng, cfg)
        };
        let writer = pool.writer(&act, &mut rng, cfg.writers);
        pool.note(label, &act, writer);
        steps.push(Step { label, writer, act });
    }
    steps
}
