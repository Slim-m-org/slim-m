// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How many WebSockets each device has open, so the last one closing is known.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::ids::{DeviceId, UserId};

#[derive(Clone, Default)]
pub struct DeviceSockets {
    open: Arc<Mutex<HashMap<(UserId, DeviceId), usize>>>,
}

impl DeviceSockets {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<(UserId, DeviceId), usize>> {
        self.open
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn opened(&self, user_id: UserId, device: DeviceId) {
        *self.lock().entry((user_id, device)).or_default() += 1;
    }

    pub fn any_open(&self, user_id: UserId, device: DeviceId) -> bool {
        self.lock().contains_key(&(user_id, device))
    }

    /// Records a close, returning whether it was the device's last open socket.
    pub fn closed(&self, user_id: UserId, device: DeviceId) -> bool {
        let mut open = self.lock();
        let Some(count) = open.get_mut(&(user_id, device)) else {
            return false;
        };
        *count -= 1;
        if *count > 0 {
            return false;
        }
        open.remove(&(user_id, device));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_last_close_of_a_device_reports_it() {
        let sockets = DeviceSockets::default();
        let (user, phone, laptop) = (
            UserId::generate(),
            DeviceId::generate(),
            DeviceId::generate(),
        );
        sockets.opened(user, phone);
        sockets.opened(user, phone);
        sockets.opened(user, laptop);
        assert!(!sockets.closed(user, phone));
        assert!(sockets.closed(user, phone));
        assert!(sockets.closed(user, laptop));
        assert!(
            !sockets.closed(user, laptop),
            "an unknown close is not a last close"
        );
    }
}
