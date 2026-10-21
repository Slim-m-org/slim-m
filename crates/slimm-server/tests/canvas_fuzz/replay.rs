// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A reference client: folds the paged ops feed into the objects it says are
//! alive, with a cold-fetch constructor for the join-then-catch-up flow.

use std::collections::{BTreeMap, HashMap};

use slimm_server::ids::{CanvasObjectId, ChannelId, UserId};
use slimm_server::store::{CanvasObject, CanvasOpBody, Rect, Store, ViewportQuery};

use crate::script::Bounds;

#[derive(Clone, Debug, PartialEq)]
pub struct Held {
    pub kind: String,
    pub author: Option<UserId>,
    pub seq: i64,
    pub b: Bounds,
    pub z: i64,
    pub props: String,
    pub alive: bool,
}

impl From<CanvasObject> for Held {
    fn from(o: CanvasObject) -> Self {
        Self {
            kind: o.kind,
            author: o.author_id,
            seq: o.seq.0,
            b: (o.x, o.y, o.w, o.h),
            z: o.z_index,
            props: o.props,
            alive: true,
        }
    }
}

#[derive(Default)]
pub struct Client {
    pub held: HashMap<CanvasObjectId, Held>,
    pub cursor: i64,
}

pub fn whole_world() -> ViewportQuery {
    ViewportQuery {
        view: Rect {
            min_x: -1e7,
            min_y: -1e7,
            max_x: 1e7,
            max_y: 1e7,
        },
        previous: None,
        after_seq: 0,
        limit: 1_000_000,
    }
}

impl Client {
    pub async fn cold(store: &Store, channel: ChannelId) -> Result<Self, String> {
        let (latest, objects) = store
            .viewport_snapshot(channel, &whole_world())
            .await
            .map_err(|e| e.to_string())?;
        Ok(Self {
            held: objects.into_iter().map(|o| (o.id, Held::from(o))).collect(),
            cursor: latest,
        })
    }

    pub fn alive(&self) -> BTreeMap<CanvasObjectId, Held> {
        self.held
            .iter()
            .filter(|(_, h)| h.alive)
            .map(|(id, h)| (*id, h.clone()))
            .collect()
    }

    /// Pages the feed from the cursor to the head, falling back to a cold fetch on a reset.
    pub async fn catch_up(
        &mut self,
        store: &Store,
        channel: ChannelId,
        page: i64,
        refetch: bool,
    ) -> Result<(), String> {
        loop {
            let feed = store
                .list_canvas_ops(channel, self.cursor, page)
                .await
                .map_err(|e| e.to_string())?;
            if feed.reset {
                // A reset is the server saying the log can no longer be replayed from here; a real client refetches.
                *self = Self::cold(store, channel).await?;
                return Ok(());
            }
            for op in &feed.ops {
                self.apply(&op.body);
                self.cursor = op.seq;
            }
            if !feed.has_more {
                self.cursor = self.cursor.max(feed.latest_seq);
                return self.settle(store, channel, refetch).await;
            }
        }
    }

    async fn settle(
        &mut self,
        store: &Store,
        channel: ChannelId,
        refetch: bool,
    ) -> Result<(), String> {
        let missing: Vec<CanvasObjectId> = self
            .held
            .iter()
            .filter(|(_, h)| h.seq < 0)
            .map(|(id, _)| *id)
            .collect();
        if missing.is_empty() || !refetch {
            self.held.retain(|_, h| h.seq >= 0);
            return Ok(());
        }
        let (_, objects) = store
            .viewport_snapshot(channel, &whole_world())
            .await
            .map_err(|e| e.to_string())?;
        let fetched: HashMap<CanvasObjectId, CanvasObject> =
            objects.into_iter().map(|o| (o.id, o)).collect();
        for id in missing {
            match fetched.get(&id) {
                Some(o) => {
                    self.held.insert(id, Held::from(o.clone()));
                }
                None => {
                    self.held.remove(&id);
                }
            }
        }
        Ok(())
    }

    fn apply(&mut self, body: &CanvasOpBody) {
        match body {
            CanvasOpBody::Place(Some(o)) => {
                self.held.insert(o.id, Held::from(o.clone()));
            }
            CanvasOpBody::Place(None) => {}
            CanvasOpBody::Remove(ids) => {
                for id in ids {
                    if let Some(h) = self.held.get_mut(id) {
                        h.alive = false;
                    }
                }
            }
            CanvasOpBody::Clear {
                before_seq,
                scope,
                spared,
            } => {
                for (id, h) in self.held.iter_mut() {
                    let kind_ok = scope.kinds.is_empty() || scope.kinds.contains(&h.kind);
                    let author_ok = scope.author_id.is_none_or(|a| h.author == Some(a));
                    if h.alive
                        && h.seq <= *before_seq
                        && kind_ok
                        && author_ok
                        && !spared.contains(id)
                    {
                        h.alive = false;
                    }
                }
            }
            CanvasOpBody::Restore { object_ids, .. } => {
                for id in object_ids {
                    match self.held.get_mut(id) {
                        Some(h) => h.alive = true,
                        None => {
                            let unknown = Held {
                                kind: String::new(),
                                author: None,
                                seq: -1,
                                b: (0.0, 0.0, 0.0, 0.0),
                                z: 0,
                                props: String::new(),
                                alive: true,
                            };
                            self.held.insert(*id, unknown);
                        }
                    }
                }
            }
            CanvasOpBody::Move {
                object_id,
                x,
                y,
                w,
                h,
            } => {
                if let Some(held) = self.held.get_mut(object_id) {
                    held.b = (*x, *y, *w, *h);
                }
            }
            CanvasOpBody::Reorder { object_id, z_index } => {
                if let Some(held) = self.held.get_mut(object_id) {
                    held.z = *z_index;
                }
            }
            CanvasOpBody::Edit { object_id, props } => {
                if let Some(held) = self.held.get_mut(object_id) {
                    held.props.clone_from(props);
                }
            }
        }
    }
}

/// The first difference between two alive sets, or `None` when they agree.
pub fn first_diff(
    label: &str,
    got: &BTreeMap<CanvasObjectId, Held>,
    want: &BTreeMap<CanvasObjectId, Held>,
) -> Option<String> {
    for (id, w) in want {
        match got.get(id) {
            None => {
                return Some(format!(
                    "{label}: {id} is alive in the table but missing from the replay"
                ));
            }
            Some(g) if g != w => {
                return Some(format!(
                    "{label}: {id} differs, replay {g:?} vs table {w:?}"
                ));
            }
            Some(_) => {}
        }
    }
    got.keys()
        .find(|id| !want.contains_key(id))
        .map(|id| format!("{label}: {id} is alive in the replay but not in the table"))
}
