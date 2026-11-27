// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Many ops in one transaction: every op applies or none does.

use super::canvas_ops_write::{CanvasOpRequest, SubmitOpError, SubmittedOp};
use crate::ids::{CanvasOpId, ChannelId, UserId};
use crate::store::Store;

/// A batch refused: which op, and why.
#[derive(Debug)]
pub struct OpBatchError {
    pub index: usize,
    pub error: SubmitOpError,
}

impl Store {
    /// Applies each op in order, with its own seq and audit rows, exactly as `submit_canvas_op`
    /// would; the first refusal rolls the whole batch back and names its index.
    pub async fn submit_canvas_ops(
        &self,
        channel_id: ChannelId,
        actor_id: UserId,
        may_moderate: bool,
        ops: Vec<(CanvasOpId, CanvasOpRequest)>,
    ) -> Result<Vec<SubmittedOp>, OpBatchError> {
        let at = |index| move |error: SubmitOpError| OpBatchError { index, error };
        let mut tx = self.begin_write().await.map_err(|e| at(0)(e.into()))?;
        let mut applied = Vec::with_capacity(ops.len());
        for (index, (op_id, request)) in ops.into_iter().enumerate() {
            let outcome = self
                .submit_op_in_tx(&mut tx, channel_id, actor_id, op_id, may_moderate, request)
                .await
                .map_err(at(index))?;
            applied.push(outcome);
        }
        tx.commit().await.map_err(|e| at(0)(e.into()))?;
        Ok(applied)
    }
}
