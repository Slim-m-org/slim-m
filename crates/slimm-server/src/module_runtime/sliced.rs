// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Calling a module export in fuel slices so the wall-clock deadline stops the
//! interpreter, and wording for every way a call can end badly.

use std::time::Instant;

use wasmi::core::TrapCode;
use wasmi::{AsContextMut, Store, TypedFunc, TypedResumableCall, WasmParams, WasmResults};

use super::host::RunError;

/// Fuel handed to the interpreter between deadline checks: a few
/// milliseconds of work, so a timed-out module stops within a few
/// milliseconds of its deadline rather than when its whole budget is spent.
const SLICE_FUEL: u64 = 1_000_000;

/// The run's total fuel, spent a slice at a time across every call.
pub struct FuelBudget {
    remaining: u64,
}

impl FuelBudget {
    pub fn new(total: u64) -> Self {
        Self { remaining: total }
    }

    /// Moves the next slice into the store, or `None` once the budget is spent.
    pub fn next_slice<T>(&mut self, store: &mut Store<T>) -> Result<Option<()>, wasmi::Error> {
        if self.remaining == 0 {
            return Ok(None);
        }
        let slice = self.remaining.min(SLICE_FUEL);
        self.remaining -= slice;
        store.set_fuel(slice)?;
        Ok(Some(()))
    }

    /// Returns fuel the store holds but did not burn, so the budget is charged
    /// for what a call consumed rather than for each slice it was handed.
    fn reclaim<T>(&mut self, store: &mut Store<T>) -> Result<(), wasmi::Error> {
        self.remaining += store.get_fuel()?;
        store.set_fuel(0)?;
        Ok(())
    }
}

/// Calls `func`, topping up fuel one slice at a time. Between slices the
/// deadline is checked, so the call ends with [`RunError::Timeout`] soon after
/// it passes; the module's fuel budget running out is the usual
/// [`RunError::ResourceLimited`].
pub fn call_sliced<T, P: WasmParams, R: WasmResults>(
    store: &mut Store<T>,
    func: &TypedFunc<P, R>,
    params: P,
    (budget, deadline): (&mut FuelBudget, Instant),
) -> Result<R, RunError> {
    // Reclaiming inside the out-of-fuel loop below could hand back a residue too small for the next instruction forever.
    budget.reclaim(store).map_err(classify_trap)?;
    if budget.next_slice(store).map_err(classify_trap)?.is_none() {
        return Err(classify_trap(wasmi::Error::from(TrapCode::OutOfFuel)));
    }
    let mut call = func.call_resumable(store.as_context_mut(), params);
    loop {
        match call.map_err(classify_trap)? {
            TypedResumableCall::Finished(results) => return Ok(results),
            TypedResumableCall::HostTrap(trap) => {
                return Err(RunError::Trap(trap.host_error().to_string()));
            }
            TypedResumableCall::OutOfFuel(paused) => {
                if Instant::now() > deadline {
                    return Err(RunError::Timeout);
                }
                if budget.next_slice(store).map_err(classify_trap)?.is_none() {
                    return Err(classify_trap(wasmi::Error::from(TrapCode::OutOfFuel)));
                }
                call = paused.resume(store.as_context_mut());
            }
        }
    }
}

/// Fuel exhaustion and a limiter-denied memory growth both surface as a
/// [`TrapCode`], so both map to [`RunError::ResourceLimited`]; every other
/// trap is the module's own bug, not a limit, and maps to [`RunError::Trap`].
pub fn classify_trap(err: wasmi::Error) -> RunError {
    match err.as_trap_code() {
        Some(TrapCode::OutOfFuel) => {
            RunError::ResourceLimited("exceeded its fuel (CPU) budget".to_owned())
        }
        Some(TrapCode::GrowthOperationLimited) => {
            RunError::ResourceLimited("exceeded its memory budget".to_owned())
        }
        Some(code) => RunError::Trap(trap_sentence(code).to_owned()),
        None => RunError::Trap(err.to_string()),
    }
}

fn trap_sentence(code: TrapCode) -> &'static str {
    match code {
        TrapCode::UnreachableCodeReached => "it hit an unreachable instruction",
        TrapCode::MemoryOutOfBounds => "it read or wrote outside its memory",
        TrapCode::TableOutOfBounds => "it indexed past the end of its table",
        TrapCode::IndirectCallToNull => "it called a function that does not exist",
        TrapCode::IntegerDivisionByZero => "it divided an integer by zero",
        TrapCode::IntegerOverflow => "an integer operation overflowed",
        TrapCode::BadConversionToInteger => "it converted a float that does not fit an integer",
        TrapCode::StackOverflow => "it recursed too deeply and overflowed its stack",
        TrapCode::BadSignature => "it called a function through the wrong signature",
        TrapCode::OutOfFuel => "it ran out of fuel",
        TrapCode::GrowthOperationLimited => "it tried to grow past a limit",
    }
}
