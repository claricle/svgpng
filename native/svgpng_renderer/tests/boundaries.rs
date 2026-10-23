//! Caller-side ABI boundary checks, separate from pinned renderer sources.
use serde_json::{Value, json};
use std::{ptr, slice};
use svgpng_renderer::{svgpng_v1_render, svgpng_v1_render_free, svgpng_v1_root_attributes};

#[repr(C)]
struct FontInput {
    bytes: *const u8,
    length: usize,
    requested_family: *const u8,
    family_length: usize,
    source_id: *const u8,
    source_id_length: usize,
    fallback_order: usize,
}

#[repr(C)]
struct Options {
    abi_version: u32,
    width: u32,
    height: u32,
    background_rgba: u32,
    intrinsic_width: f64,
    intrinsic_height: f64,
    fit: f64,
    translate_x: f64,
    translate_y: f64,
}

#[repr(C)]
struct Output {
    pixels: *mut u8,
    pixels_length: usize,
    diagnostics: *mut u8,
    diagnostics_length: usize,
}

impl Output {
    fn empty() -> Self {
        Self {
            pixels: ptr::null_mut(),
            pixels_length: 0,
            diagnostics: ptr::null_mut(),
            diagnostics_length: 0,
        }
    }

    fn finish(&mut self, code: i32) -> (i32, usize, Value) {
        let pixel_length = self.pixels_length;
        assert!(!self.diagnostics.is_null());
        let detail = serde_json::from_slice(unsafe {
            slice::from_raw_parts(self.diagnostics, self.diagnostics_length)
        })
        .unwrap();
        unsafe { svgpng_v1_render_free(ptr::from_mut(self).cast()) };
        assert!(self.pixels.is_null());
        assert!(self.diagnostics.is_null());
        assert_eq!(self.pixels_length, 0);
        assert_eq!(self.diagnostics_length, 0);
        unsafe { svgpng_v1_render_free(ptr::from_mut(self).cast()) };
        (code, pixel_length, detail)
    }
}

fn root(svg: &str) -> (i32, usize, Value) {
    let mut out = Output::empty();
    let code = unsafe {
        svgpng_v1_root_attributes(svg.as_ptr(), svg.len(), ptr::from_mut(&mut out).cast())
    };
    assert_eq!(out.pixels_length, 0);
    out.finish(code)
}

fn render(svg: &str, fonts: &[FontInput]) -> (i32, usize, Value) {
    let options = Options {
        abi_version: 1,
        width: 2,
        height: 2,
        background_rgba: 0,
        intrinsic_width: 2.,
        intrinsic_height: 2.,
        fit: 1.,
        translate_x: 0.,
        translate_y: 0.,
    };
    let mut out = Output::empty();
    let code = unsafe {
        svgpng_v1_render(
            svg.as_ptr(),
            svg.len(),
            fonts.as_ptr().cast(),
            fonts.len(),
            ptr::from_ref(&options).cast(),
            ptr::from_mut(&mut out).cast(),
        )
    };
    out.finish(code)
}

#[test]
fn svg_byte_budget_accepts_exact_limit_and_rejects_one_more() {
    // A comment keeps the 16 MiB input independent of element/pixel budgets.
    let prefix = "<svg xmlns='http://www.w3.org/2000/svg'><!--";
    let suffix = "--></svg>";
    let mut svg = format!(
        "{prefix}{}{suffix}",
        "x".repeat(16 * 1024 * 1024 - prefix.len() - suffix.len())
    );
    assert_eq!(svg.len(), 16 * 1024 * 1024);
    assert_eq!(root(&svg).0, 0);
    let accepted = render(&svg, &[]);
    assert_eq!(accepted.0, 0);
    assert_eq!(accepted.1, 2 * 2 * 4);
    svg.push(' ');
    let limit = (2, 0, json!({"error":{"status":2}}));
    assert_eq!(root(&svg), limit);
    assert_eq!(render(&svg, &[]), limit);
    assert_eq!(render("<svg/>", &[]).0, 0);
}

#[test]
fn font_input_count_accepts_64_at_validation_then_rejects_65() {
    // Invalid bytes stop at metadata parsing: 64 passes the count guard,
    // without needing 64 distinct valid font fixtures.
    let fonts = (0..65)
        .map(|_| FontInput {
            bytes: b"invalid".as_ptr(),
            length: 7,
            requested_family: b"Noto Sans".as_ptr(),
            family_length: 9,
            source_id: b"fixture".as_ptr(),
            source_id_length: 7,
            fallback_order: usize::MAX,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        render("<svg/>", &fonts[..64]),
        (3, 0, json!({"error":{"status":3}}))
    );
    assert_eq!(
        render("<svg/>", &fonts),
        (2, 0, json!({"error":{"status":2}}))
    );
}

#[test]
fn css_nesting_budget_accepts_128_and_rejects_129() {
    let svg = |depth| {
        format!(
            "<svg style='{}red{}'/>",
            "f(".repeat(depth),
            ")".repeat(depth)
        )
    };
    assert_eq!(root(&svg(128)).0, 0);
    assert_eq!(root(&svg(129)), (2, 0, json!({"error":{"status":2}})));
    assert_eq!(root(&svg(128)).0, 0);
}
