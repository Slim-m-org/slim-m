// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! [`ModuleHost`]: the wasmi instantiation and call sequence behind
//! [`super`]'s ABI, and every way it can fail cleanly instead of hanging or
//! panicking the caller.

use std::fmt;
use std::time::Instant;

use sha2::{Digest, Sha256};
use wasmi::{
    Caller, Extern, Instance, Linker, Memory, Module, Store as WasmiStore, StoreContext,
    StoreLimits,
};

use super::capabilities::CapabilitySurface;
use super::compiled::{compiled_module, shared_engine};
use super::limits::{MAX_RESPONSE_BYTES, RunLimits, store_limits};
use super::sliced::{FuelBudget, call_sliced};
use crate::media::to_hex;

/// Why a run did not produce the module's own response bytes. Every variant
/// is a clean, typed outcome - `http::module_commands` turns each into an
/// `{ "ok": false, "error": ... }` body, never a 500 and never a hang.
#[derive(Debug)]
pub enum RunError {
    /// The stored artifact's sha256 no longer matches what was recorded at
    /// install time.
    HashMismatch,
    /// The module declares at least one wasm import. Per the ABI (see
    /// `super`'s module doc), a v1 module may only compute; the host refuses
    /// to instantiate anything that asks for a host function, memory import,
    /// or anything else.
    ImportsNotAllowed,
    /// The wasm bytes did not parse, did not instantiate, or did not export
    /// the ABI's `memory`, `alloc`, and `run`.
    Instantiate(String),
    /// `alloc` or `run` trapped for a reason other than a resource limit
    /// (an out-of-bounds access, an integer overflow, an explicit
    /// `unreachable`, and so on).
    Trap(String),
    /// The module ran into its fuel or memory ceiling.
    ResourceLimited(String),
    /// The wall-clock cap elapsed before `run` returned.
    Timeout,
}

impl fmt::Display for RunError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RunError::HashMismatch => write!(f, "module artifact failed integrity verification"),
            RunError::ImportsNotAllowed => {
                write!(f, "module declares an import, which v1 modules may not do")
            }
            RunError::Instantiate(detail) => write!(f, "module failed to load: {detail}"),
            RunError::Trap(detail) => write!(f, "module trapped: {detail}"),
            RunError::ResourceLimited(detail) => write!(f, "module exceeded its limits: {detail}"),
            RunError::Timeout => write!(f, "module timed out"),
        }
    }
}

/// The Phase 3 module host: given a module's own wasm bytes, runs its `run`
/// export against one request under the caller-supplied [`RunLimits`]. See
/// [`super`]'s module doc for the wire ABI this assumes.
pub struct ModuleHost;

impl ModuleHost {
    /// Verifies `wasm`'s sha256 against `expected_sha256`, then instantiates
    /// and calls it on a blocking task bounded by `limits.wall`. The run
    /// executes in fuel slices and checks the deadline between them, so a
    /// timeout also stops the wasm; the outer timeout is only a backstop for
    /// a task that never reaches a slice boundary.
    pub async fn run(
        wasm: Vec<u8>,
        expected_sha256: String,
        limits: RunLimits,
        input: Vec<u8>,
    ) -> Result<Vec<u8>, RunError> {
        Self::run_with_capabilities(
            wasm,
            expected_sha256,
            limits,
            input,
            CapabilitySurface::Disabled,
        )
        .await
    }

    /// As [`run`](Self::run), but with a mediated-capability surface available
    /// to the module (decision 0023). With [`CapabilitySurface::Disabled`] this
    /// is exactly [`run`](Self::run) - a module may import nothing. With it
    /// enabled and at least one capability approved, the module may import the
    /// single `slim.host_call` function (and nothing else), whose requests are
    /// gated by the surface; every other import is still refused.
    ///
    /// A host call made after the wall-clock deadline is refused, so a run the
    /// caller has already given up on cannot keep acting through a capability.
    pub async fn run_with_capabilities(
        wasm: Vec<u8>,
        expected_sha256: String,
        limits: RunLimits,
        input: Vec<u8>,
        surface: CapabilitySurface,
    ) -> Result<Vec<u8>, RunError> {
        let digest = to_hex(&Sha256::digest(&wasm));
        if digest != expected_sha256 {
            return Err(RunError::HashMismatch);
        }

        let wall = limits.wall;
        let deadline = Instant::now() + wall;
        let task = tokio::task::spawn_blocking(move || {
            let module = compiled_module(&digest, &wasm)?;
            run_sync(&module, limits, &input, (surface, deadline))
        });
        match tokio::time::timeout(wall, task).await {
            Ok(Ok(result)) => result,
            Ok(Err(_join_error)) => Err(RunError::Trap("module task did not complete".to_owned())),
            Err(_elapsed) => Err(RunError::Timeout),
        }
    }
}

/// A module run's store data: the memory/fuel limiter as before, plus the
/// capability surface a `slim.host_call` host function reads to gate a request.
struct HostState {
    limits: StoreLimits,
    surface: CapabilitySurface,
    deadline: Instant,
}

fn run_sync(
    module: &Module,
    limits: RunLimits,
    input: &[u8],
    (surface, deadline): (CapabilitySurface, Instant),
) -> Result<Vec<u8>, RunError> {
    let engine = shared_engine();
    // The only import a module may declare is the single gated `slim.host_call`, and only with the surface on and a capability approved; every other case (any import while off, any other import ever, a second import) is refused, the same no-ambient-authority rule v1 has always had (decisions 0021, 0023).
    let allows_host_call = surface.allows_host_call();
    let mut imports_host_call = false;
    for import in module.imports() {
        if allows_host_call && import.module() == "slim" && import.name() == "host_call" {
            imports_host_call = true;
        } else {
            return Err(RunError::ImportsNotAllowed);
        }
    }

    let mut store = WasmiStore::new(
        engine,
        HostState {
            limits: store_limits(limits.memory_bytes),
            surface,
            deadline,
        },
    );
    store.limiter(|state| &mut state.limits);
    let mut budget = FuelBudget::new(limits.fuel);
    budget
        .next_slice(&mut store)
        .map_err(|e| RunError::Instantiate(format!("failed to configure fuel: {e}")))?;

    let instance = if imports_host_call {
        let mut linker = Linker::<HostState>::new(engine);
        linker
            .func_wrap("slim", "host_call", host_call)
            .map_err(|e| RunError::Instantiate(format!("failed to define host_call: {e}")))?;
        // A slim module has no wasm start function, so instantiate-and-start is just instantiation; the response comes from `run`, called below.
        linker
            .instantiate_and_start(&mut store, module)
            .map_err(|e| RunError::Instantiate(format!("module failed to instantiate: {e}")))?
    } else {
        Instance::new(&mut store, module, &[])
            .map_err(|e| RunError::Instantiate(format!("module failed to instantiate: {e}")))?
    };

    let memory = instance.get_memory(&store, "memory").ok_or_else(|| {
        RunError::Instantiate("module does not export a memory named \"memory\"".to_owned())
    })?;
    let alloc = instance
        .get_typed_func::<i32, i32>(&store, "alloc")
        .map_err(|e| RunError::Instantiate(format!("module does not export alloc: {e}")))?;
    let run = instance
        .get_typed_func::<(i32, i32), i64>(&store, "run")
        .map_err(|e| RunError::Instantiate(format!("module does not export run: {e}")))?;

    let in_len = i32::try_from(input.len())
        .map_err(|_| RunError::Instantiate("request too large for a wasm module".to_owned()))?;
    let in_ptr = call_sliced(&mut store, &alloc, in_len, (&mut budget, deadline))?;
    memory
        .write(&mut store, in_ptr as usize, input)
        .map_err(|e| RunError::Instantiate(format!("module's alloc returned bad memory: {e}")))?;

    let packed = call_sliced(&mut store, &run, (in_ptr, in_len), (&mut budget, deadline))?;
    let out_ptr = (packed >> 32) as u32 as usize;
    let out_len = (packed & 0xffff_ffff) as u32 as usize;
    let inside_memory = out_ptr
        .checked_add(out_len)
        .is_some_and(|end| end <= memory.data_size(&store));
    if inside_memory && out_len > MAX_RESPONSE_BYTES {
        return Err(RunError::ResourceLimited(format!(
            "its response is larger than the {MAX_RESPONSE_BYTES} byte limit"
        )));
    }
    read_guest(&memory, &store, out_ptr, out_len).ok_or_else(|| {
        RunError::Trap("run returned a response region outside the module's memory".to_owned())
    })
}

/// A bounds-checked copy of `len` bytes at `ptr` in the module's memory, or
/// `None` when the region does not lie entirely inside it. The pointer and
/// length both come from the module, so they are checked against the memory's
/// real size before any host-side buffer is allocated: a module claiming a
/// 4 GiB response gets a refusal, not a 4 GiB allocation.
fn read_guest<'a, T: 'a>(
    memory: &Memory,
    ctx: impl Into<StoreContext<'a, T>>,
    ptr: usize,
    len: usize,
) -> Option<Vec<u8>> {
    let end = ptr.checked_add(len)?;
    memory.data(ctx).get(ptr..end).map(<[u8]>::to_vec)
}

/// The single host function a capability-using module may import. It reads the
/// UTF-8 JSON request from the module's memory, hands it to the surface to gate
/// and answer (see [`super::capabilities`]), then writes the response back into
/// the module's own memory using the module's own `alloc` export - so the
/// response lives in the module's address space, never the host's - and returns
/// the packed `(out_ptr << 32) | out_len`, the same convention `run` uses.
///
/// Every failure path returns `0` (an empty response), which the module reads
/// as "no bytes" and treats as an error; a misbehaving module can make this
/// return nothing but can never make it read or write outside its own memory,
/// nor turn a bad request into a host error.
/// Largest request a module may hand `host_call`: above the biggest real one
/// (a `net.fetch` with its 64 KiB body), checked before anything is copied.
const MAX_HOST_CALL_REQUEST_BYTES: usize = 128 * 1024;

fn host_call(mut caller: Caller<'_, HostState>, req_ptr: i32, req_len: i32) -> i64 {
    if Instant::now() > caller.data().deadline {
        return 0;
    }
    let Some(Extern::Memory(memory)) = caller.get_export("memory") else {
        return 0;
    };
    let Ok(req_len) = usize::try_from(req_len) else {
        return 0;
    };
    if req_len > MAX_HOST_CALL_REQUEST_BYTES {
        return 0;
    }
    let Ok(req_ptr) = usize::try_from(req_ptr) else {
        return 0;
    };
    let Some(request) = read_guest(&memory, &caller, req_ptr, req_len) else {
        return 0;
    };

    // The borrow of `caller` ends when `dispatch` returns its owned bytes, so the alloc/write below can take `caller` mutably.
    let response = caller.data_mut().surface.dispatch(&request);

    let Some(Extern::Func(alloc)) = caller.get_export("alloc") else {
        return 0;
    };
    let Ok(alloc) = alloc.typed::<i32, i32>(&caller) else {
        return 0;
    };
    let Ok(out_len) = i32::try_from(response.len()) else {
        return 0;
    };
    let Ok(out_ptr) = alloc.call(&mut caller, out_len) else {
        return 0;
    };
    if memory
        .write(&mut caller, out_ptr as usize, &response)
        .is_err()
    {
        return 0;
    }
    ((out_ptr as i64) << 32) | (out_len as i64 & 0xffff_ffff)
}
