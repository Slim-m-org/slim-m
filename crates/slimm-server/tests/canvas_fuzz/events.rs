// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The live event stream and the catch-up feed describe the same ops: every
//! fresh, effective op published exactly one frame, naming what the feed names.

use std::collections::BTreeMap;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::Event;
use slimm_server::store::CanvasOpBody;

use crate::fixtures::{
    self, general, id, new_store_and_pool, post_object, register, stroke, submit_op,
};
use crate::script::Rng;

fn note(text: &str) -> Value {
    json!({ "id": id(), "kind": "note", "x": 5.0, "y": 5.0, "w": 100.0, "h": 80.0, "props": { "text": text } })
}

fn random_body(
    rng: &mut Rng,
    (objects, notes): (&[String], &[String]),
    erasures: &[String],
    head: i64,
) -> Value {
    let pick = |rng: &mut Rng| objects[rng.below(objects.len() as u64) as usize].clone();
    match rng.below(8) {
        0 | 1 => {
            let ids: std::collections::BTreeSet<String> =
                [pick(rng), pick(rng)].into_iter().collect();
            json!({ "id": id(), "kind": "remove", "object_ids": ids })
        }
        2 => json!({ "id": id(), "kind": "clear", "before_seq": rng.range(0, head) }),
        3 => json!({ "id": id(), "kind": "clear_scoped", "before_seq": head, "kinds": ["note"] }),
        4 | 5 if !erasures.is_empty() => {
            json!({ "id": id(), "kind": "restore", "target_op": erasures[rng.below(erasures.len() as u64) as usize] })
        }
        6 => {
            json!({ "id": id(), "kind": "move", "object_id": pick(rng), "x": rng.range(-90, 90), "y": 3, "w": 40, "h": 40 })
        }
        _ if rng.chance(50) => {
            json!({ "id": id(), "kind": "reorder", "object_id": pick(rng), "z_index": rng.range(0, 99) })
        }
        _ => {
            json!({ "id": id(), "kind": "edit", "object_id": notes[rng.below(notes.len() as u64) as usize], "props": { "text": format!("t{}", rng.below(4)) } })
        }
    }
}

#[tokio::test]
async fn every_effective_op_publishes_one_frame_that_matches_the_feed() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (root, _) = register(&store, "root").await;
    let (bob, _) = fixtures::member(&store, "bob").await;
    let (cat, _) = fixtures::member(&store, "cat").await;
    let channel = general(&store).await;
    let state = crate::support::app::state(store.clone());
    let mut frames = state.hub.subscribe();
    let router = slimm_server::http::router(state);

    let mut objects = Vec::new();
    let mut notes = Vec::new();
    for n in 0..24 {
        let token = [&root, &bob, &cat][n % 3];
        let body = if n % 2 == 0 {
            stroke(&id())
        } else {
            note("start")
        };
        let (status, placed) = post_object(&router, channel, token, body).await;
        assert_eq!(status, StatusCode::CREATED, "{placed}");
        objects.push(placed["id"].as_str().unwrap().to_owned());
        if n % 2 == 1 {
            notes.push(placed["id"].as_str().unwrap().to_owned());
        }
    }
    let mut rng = Rng::new(7);
    let mut erasures = Vec::new();
    for n in 0..120 {
        let head = store
            .list_canvas_ops(channel, 0, 1)
            .await
            .unwrap()
            .latest_seq;
        let body = random_body(&mut rng, (&objects, &notes), &erasures, head);
        let token = if ["edit", "move", "reorder"].contains(&body["kind"].as_str().unwrap_or("")) {
            &root
        } else {
            [&root, &bob, &cat][n % 3]
        };
        let kind = body["kind"].as_str().unwrap().to_owned();
        let (status, reply) = submit_op(&router, channel, token, body).await;
        if status == StatusCode::CREATED
            && reply["op"]["affected"].as_i64() > Some(0)
            && matches!(kind.as_str(), "remove" | "clear" | "clear_scoped")
        {
            erasures.push(reply["op"]["id"].as_str().unwrap().to_owned());
        }
    }

    let mut published: BTreeMap<i64, Event> = BTreeMap::new();
    while let Ok(event) = frames.try_recv() {
        let seq = match &event {
            Event::CanvasObjectPlaced { object, .. } => object.seq.0,
            Event::CanvasObjectsRemoved { seq, .. }
            | Event::CanvasCleared { seq, .. }
            | Event::CanvasObjectsRestored { seq, .. }
            | Event::CanvasObjectMoved { seq, .. }
            | Event::CanvasObjectReordered { seq, .. }
            | Event::CanvasObjectEdited { seq, .. } => seq.0,
            _ => continue,
        };
        assert!(
            published.insert(seq, event).is_none(),
            "seq {seq} was published twice"
        );
    }

    let page = store.list_canvas_ops(channel, 0, 500).await.unwrap();
    assert!(!page.has_more);
    assert_eq!(published.len(), page.ops.len(), "frames and feed rows");
    let kinds: std::collections::BTreeSet<&str> = page
        .ops
        .iter()
        .map(|op| match op.body {
            CanvasOpBody::Place(_) => "place",
            CanvasOpBody::Remove(_) => "remove",
            CanvasOpBody::Clear { .. } => "clear",
            CanvasOpBody::Restore { .. } => "restore",
            CanvasOpBody::Move { .. } => "move",
            CanvasOpBody::Reorder { .. } => "reorder",
            CanvasOpBody::Edit { .. } => "edit",
        })
        .collect();
    assert_eq!(kinds.len(), 7, "the run only produced {kinds:?}");
    for op in &page.ops {
        let event = published
            .get(&op.seq)
            .unwrap_or_else(|| panic!("seq {} has no frame", op.seq));
        match (&op.body, event) {
            (CanvasOpBody::Place(_), Event::CanvasObjectPlaced { .. }) => {}
            (CanvasOpBody::Remove(ids), Event::CanvasObjectsRemoved { object_ids, .. }) => {
                assert_eq!(ids, object_ids, "remove at {}", op.seq)
            }
            (
                CanvasOpBody::Clear {
                    before_seq,
                    scope,
                    spared,
                },
                Event::CanvasCleared {
                    before_seq: b,
                    scope: s,
                    spared_count,
                    ..
                },
            ) => {
                assert_eq!((*before_seq, scope), (b.0, s), "clear at {}", op.seq);
                assert_eq!(spared.len() as i64, *spared_count, "spared at {}", op.seq);
            }
            (
                CanvasOpBody::Restore { object_ids, .. },
                Event::CanvasObjectsRestored {
                    object_ids: framed, ..
                },
            ) => {
                assert!(
                    framed == object_ids || (framed.is_empty() && object_ids.len() > 64),
                    "restore at {}",
                    op.seq
                );
            }
            (
                CanvasOpBody::Move {
                    object_id,
                    x,
                    y,
                    w,
                    h,
                },
                Event::CanvasObjectMoved {
                    object_id: o,
                    x: fx,
                    y: fy,
                    w: fw,
                    h: fh,
                    ..
                },
            ) => assert_eq!(
                (object_id, x, y, w, h),
                (o, fx, fy, fw, fh),
                "move at {}",
                op.seq
            ),
            (
                CanvasOpBody::Reorder { object_id, z_index },
                Event::CanvasObjectReordered {
                    object_id: o,
                    z_index: z,
                    ..
                },
            ) => assert_eq!((object_id, z_index), (o, z), "reorder at {}", op.seq),
            (
                CanvasOpBody::Edit { object_id, props },
                Event::CanvasObjectEdited {
                    object_id: o,
                    props: p,
                    ..
                },
            ) => assert_eq!((object_id, props), (o, p), "edit at {}", op.seq),
            (body, event) => panic!("seq {}: feed says {body:?}, frame says {event:?}", op.seq),
        }
    }
}
