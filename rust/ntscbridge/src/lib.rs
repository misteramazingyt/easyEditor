//! C-ABI shim over ntsc-rs so the iOS app can run the real signal processing
//! rather than an approximation of it.
//!
//! The app hands over a tightly packed RGBA8 buffer; ntsc-rs converts to YIQ,
//! applies the effect field by field, and writes back in place. Settings come
//! straight from the same preset JSON the desktop tool uses, so a preset means
//! here exactly what it means there.

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

use ntsc_rs::settings::SettingsList;
use ntsc_rs::yiq_fielding::Rgbx;
use ntsc_rs::{Context, NtscEffect};

pub struct Bridge {
    effect: NtscEffect,
    ctx: Context,
}

/// Build an effect from ntsc-rs preset JSON. Falls back to the default preset
/// if the JSON can't be parsed, so a bad file costs fidelity rather than the
/// feature. Returns null only if the effect itself couldn't be constructed.
///
/// `parsed_out`, if given, is set to whether the JSON actually took. Without
/// it a preset that fails to parse is indistinguishable from one that works:
/// every look silently becomes the default, which is exactly the failure that
/// is hardest to notice and worst to ship.
///
/// # Safety
/// `json` must be a valid NUL-terminated C string, or null for defaults;
/// `parsed_out` must be null or point to a writable bool.
#[no_mangle]
pub unsafe extern "C" fn ntsc_bridge_create(
    json: *const c_char,
    parsed_out: *mut bool,
) -> *mut Bridge {
    let mut parsed = false;
    let result = catch_unwind(AssertUnwindSafe(|| {
        let effect = if json.is_null() {
            NtscEffect::default()
        } else {
            match CStr::from_ptr(json).to_str() {
                Ok(text) => match SettingsList::<NtscEffect>::new().from_json_generic(text) {
                    Ok(effect) => {
                        parsed = true;
                        effect
                    }
                    Err(_) => NtscEffect::default(),
                },
                Err(_) => NtscEffect::default(),
            }
        };
        Box::into_raw(Box::new(Bridge {
            effect,
            ctx: Context::new(),
        }))
    }));
    if !parsed_out.is_null() {
        *parsed_out = parsed;
    }
    result.unwrap_or(ptr::null_mut())
}

/// Apply the effect in place to a packed RGBA8 buffer.
///
/// `frame` advances the effect's time-varying parts (head switching, noise,
/// tape wander). `scale` tells ntsc-rs how large this image is relative to a
/// broadcast frame so artefact sizes stay right when we process at reduced
/// resolution for speed.
///
/// # Safety
/// `pixels` must point to `width * height * 4` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn ntsc_bridge_process(
    handle: *mut Bridge,
    pixels: *mut u8,
    width: usize,
    height: usize,
    frame: usize,
    scale: f32,
) -> bool {
    if handle.is_null() || pixels.is_null() || width == 0 || height == 0 {
        return false;
    }
    let bridge = &*handle;
    let len = match width.checked_mul(height).and_then(|n| n.checked_mul(4)) {
        Some(len) => len,
        None => return false,
    };
    let buffer = slice::from_raw_parts_mut(pixels, len);
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };

    // A panic across the FFI boundary would be undefined behaviour.
    catch_unwind(AssertUnwindSafe(|| {
        bridge.effect.apply_effect_to_buffer::<Rgbx, u8>(
            &bridge.ctx,
            (width, height),
            buffer,
            frame,
            [scale, scale],
        );
    }))
    .is_ok()
}

/// # Safety
/// `handle` must have come from `ntsc_bridge_create` and not be used again.
#[no_mangle]
pub unsafe extern "C" fn ntsc_bridge_destroy(handle: *mut Bridge) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}
