//! Caller-owned input ABI; returned buffers must be released by render_free.
use resvg::{tiny_skia, usvg};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use skrifa::raw::TableProvider;
use std::{
    collections::HashSet,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
    sync::{Arc, Mutex},
};
use unicode_normalization::UnicodeNormalization;

const SVG_LIMIT: usize = 16 * 1024 * 1024;
const BUFFER_LIMIT: usize = 256 * 1024 * 1024;
#[repr(C)]
pub struct FontInput {
    bytes: *const u8,
    length: usize,
    requested_family: *const u8,
    family_length: usize,
    source_id: *const u8,
    source_id_length: usize,
    fallback_order: usize,
}
#[repr(C)]
pub struct RenderOptions {
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
pub struct RenderOutput {
    pixels: *mut u8,
    pixels_length: usize,
    diagnostics: *mut u8,
    diagnostics_length: usize,
}
impl RenderOutput {
    fn empty() -> Self {
        Self {
            pixels: ptr::null_mut(),
            pixels_length: 0,
            diagnostics: ptr::null_mut(),
            diagnostics_length: 0,
        }
    }
}
fn owned(bytes: Vec<u8>) -> (*mut u8, usize) {
    let mut b = bytes.into_boxed_slice();
    let r = (b.as_mut_ptr(), b.len());
    std::mem::forget(b);
    r
}
unsafe fn input<'a>(p: *const u8, n: usize, limit: usize) -> Result<&'a [u8], i32> {
    if n > limit || n > isize::MAX as usize {
        return Err(2);
    }
    if p.is_null() {
        return if n == 0 { Ok(&[]) } else { Err(1) };
    }
    Ok(unsafe { slice::from_raw_parts(p, n) })
}
fn normalized(s: &str) -> String {
    s.trim()
        .trim_matches(['\'', '"'])
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .nfc()
        .collect::<String>()
        .to_ascii_lowercase()
}
fn parse_error(e: usvg::Error) -> Failure {
    match e {
        usvg::Error::ForbiddenReferenceAt {
            reference_class,
            location,
        } => Failure {
            code: 7,
            detail: json!({"status":7,"reference_class":reference_class,"location":location}),
        },
        usvg::Error::ForbiddenReference => 7.into(),
        usvg::Error::ReferenceLimit => 2.into(),
        _ => 1.into(),
    }
}
struct Failure {
    code: i32,
    detail: Value,
}
impl From<i32> for Failure {
    fn from(code: i32) -> Self {
        Self {
            code,
            detail: json!({"status":code}),
        }
    }
}
fn font_detail(font: &usvg::Font, text: &str) -> Value {
    let mut scalars = text.chars().map(|c| c as u32).collect::<Vec<_>>();
    scalars.sort_unstable();
    scalars.dedup();
    json!({"requested_family":font.families().iter().map(|family| match family { usvg::FontFamily::Named(name) => name.clone(), generic => generic.to_string() }).collect::<Vec<_>>().join(", "),"scalars":scalars,"style":format!("{:?}",font.style()).to_ascii_lowercase(),"weight":font.weight(),"stretch":format!("{:?}",font.stretch()).to_ascii_lowercase()})
}
fn query_family(
    font: &usvg::Font,
    name: &str,
    db: &usvg::fontdb::Database,
) -> Option<usvg::fontdb::ID> {
    let actual = db
        .faces()
        .flat_map(|f| f.families.iter())
        .find(|(n, _)| normalized(n) == normalized(name))
        .map(|(n, _)| n)?;
    let style = match font.style() {
        usvg::FontStyle::Normal => usvg::fontdb::Style::Normal,
        usvg::FontStyle::Italic => usvg::fontdb::Style::Italic,
        usvg::FontStyle::Oblique => usvg::fontdb::Style::Oblique,
    };
    db.query(&usvg::fontdb::Query {
        families: &[usvg::fontdb::Family::Name(actual)],
        weight: usvg::fontdb::Weight(font.weight()),
        stretch: font.stretch().into(),
        style,
    })
}
fn finish(out: &mut RenderOutput, result: Result<(Vec<u8>, Value), Failure>) -> i32 {
    match result {
        Ok((p, d)) => {
            (out.pixels, out.pixels_length) = owned(p);
            (out.diagnostics, out.diagnostics_length) = owned(d.to_string().into_bytes());
            0
        }
        Err(error) => {
            (out.diagnostics, out.diagnostics_length) =
                owned(json!({"error":error.detail}).to_string().into_bytes());
            error.code
        }
    }
}
/// Parse guarded XML once and expose unmodified intrinsic attributes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn svgpng_v1_root_attributes(
    svg: *const u8,
    len: usize,
    output: *mut RenderOutput,
) -> i32 {
    if output.is_null() {
        return 1;
    }
    let out = unsafe { &mut *output };
    *out = RenderOutput::empty();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = std::str::from_utf8(unsafe { input(svg, len, SVG_LIMIT)? }).map_err(|_| 1)?;
        let doc = usvg::guarded_document(text).map_err(parse_error)?;
        let root = doc.root_element();
        if root.tag_name().name() != "svg" {
            return Err(1.into());
        }
        let mut attrs = serde_json::Map::new();
        for key in ["width", "height", "viewBox"] {
            if let Some(v) = root.attribute(key) {
                attrs.insert(key.into(), Value::String(v.into()));
            }
        }
        Ok((Vec::new(), Value::Object(attrs)))
    }))
    .unwrap_or_else(|_| Err(8.into()));
    finish(out, result)
}
/// Render premultiplied sRGB RGBA using supplied font bytes only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn svgpng_v1_render(
    svg: *const u8,
    len: usize,
    fonts: *const FontInput,
    count: usize,
    options: *const RenderOptions,
    output: *mut RenderOutput,
) -> i32 {
    if output.is_null() {
        return 1;
    }
    let out = unsafe { &mut *output };
    *out = RenderOutput::empty();
    let result = catch_unwind(AssertUnwindSafe(|| unsafe {
        render(svg, len, fonts, count, options)
    }))
    .unwrap_or_else(|_| Err(8.into()));
    finish(out, result)
}
unsafe fn render(
    svg: *const u8,
    len: usize,
    fonts: *const FontInput,
    count: usize,
    options: *const RenderOptions,
) -> Result<(Vec<u8>, Value), Failure> {
    if options.is_null() {
        return Err(1.into());
    }
    let o = unsafe { &*options };
    if o.abi_version != 1 {
        return Err(9.into());
    }
    if o.width == 0 || o.height == 0 || o.width > 32768 || o.height > 32768 {
        return Err(2.into());
    }
    let pixels = (o.width as usize).checked_mul(o.height as usize).ok_or(2)?;
    if pixels > 64_000_000 || pixels.checked_mul(4).ok_or(2)? > BUFFER_LIMIT {
        return Err(2.into());
    }
    if ![o.intrinsic_width, o.intrinsic_height, o.fit]
        .iter()
        .all(|n| n.is_finite() && *n > 0.)
        || ![o.translate_x, o.translate_y].iter().all(|n| n.is_finite())
    {
        return Err(1.into());
    }
    if count > 64 {
        return Err(2.into());
    }
    if count > 0 && fonts.is_null() {
        return Err(1.into());
    }
    let text = std::str::from_utf8(unsafe { input(svg, len, SVG_LIMIT)? }).map_err(|_| 1)?;
    let doc = usvg::guarded_document(text).map_err(parse_error)?;
    let mut db = usvg::fontdb::Database::new();
    let mut metadata = Vec::new();
    let mut total = 0usize;
    let mut seen = HashSet::new();
    let mut fallbacks = Vec::new();
    for f in if count == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(fonts, count) }
    } {
        total = total.checked_add(f.length).ok_or(2)?;
        if total > 128 * 1024 * 1024 {
            return Err(2.into());
        }
        let bytes = unsafe { input(f.bytes, f.length, 32 * 1024 * 1024)? };
        let family = normalized(
            std::str::from_utf8(unsafe { input(f.requested_family, f.family_length, SVG_LIMIT)? })
                .map_err(|_| 3)?,
        );
        let source =
            std::str::from_utf8(unsafe { input(f.source_id, f.source_id_length, SVG_LIMIT)? })
                .map_err(|_| 3)?;
        let face_count = match skrifa::raw::FileRef::new(bytes).map_err(|_| 3)? {
            skrifa::raw::FileRef::Font(_) => 1,
            skrifa::raw::FileRef::Collection(c) => c.len() as usize,
        };
        if db.len().checked_add(face_count).ok_or(2)? > 64 {
            return Err(2.into());
        }
        let ids = db.load_font_source(usvg::fontdb::Source::Binary(Arc::new(bytes.to_vec())));
        if ids.is_empty() {
            return Err(3.into());
        }
        for id in ids {
            let face = db.face(id).ok_or(3)?;
            let parsed = skrifa::FontRef::from_index(bytes, face.index).map_err(|_| 3)?;
            if let Ok(svg_table) = parsed.svg() {
                let list = svg_table.svg_document_list().map_err(|_| 3)?;
                for record in list.document_records() {
                    let glyph_data = svg_table
                        .glyph_data(record.start_glyph_id.get().into())
                        .map_err(|_| 3)?
                        .ok_or(3)?;
                    let glyph_text = std::str::from_utf8(glyph_data).map_err(|_| 3)?;
                    usvg::guarded_document(glyph_text).map_err(parse_error)?;
                }
            }
            let family = if family.is_empty() && f.fallback_order != usize::MAX {
                normalized(&face.families[0].0)
            } else {
                family.clone()
            };
            if !face
                .families
                .iter()
                .any(|(name, _)| normalized(name) == family)
            {
                return Err(3.into());
            }
            let key = format!(
                "{}:{:?}:{:?}:{:?}",
                family, face.style, face.weight, face.stretch
            );
            if !seen.insert(key) {
                return Err(4.into());
            }
            metadata.push(json!({"family":family,"source_id":source,"sha256":format!("{:x}",Sha256::digest(bytes)),"face_index":face.index,"style":format!("{:?}",face.style).to_ascii_lowercase(),"weight":face.weight.0,"stretch":format!("{:?}",face.stretch).to_ascii_lowercase()}));
            if f.fallback_order != usize::MAX {
                fallbacks.push((f.fallback_order, id));
            }
        }
    }
    if db.len() > 64 {
        return Err(2.into());
    }
    fallbacks.sort_by_key(|(order, _)| *order);
    let errors = Arc::new(Mutex::new(Vec::<Failure>::new()));
    let glyph_errors = errors.clone();
    let warnings = Arc::new(Mutex::new(Vec::<Value>::new()));
    let cluster_warnings = warnings.clone();
    let selected = Arc::new(Mutex::new(HashSet::new()));
    let cluster_ids = selected.clone();
    let fallback_families = fallbacks
        .iter()
        .filter_map(|(_, id)| db.face(*id).map(|face| face.families[0].0.clone()))
        .fold(Vec::<String>::new(), |mut names, name| {
            if !names.contains(&name) {
                names.push(name)
            }
            names
        });
    let family_fallback = fallback_families.clone();
    let face_metadata = db
        .faces()
        .zip(metadata.iter())
        .map(|(face, m)| (face.id, m.clone()))
        .collect::<std::collections::HashMap<_, _>>();
    let cluster_faces = face_metadata.clone();
    let primary = Arc::new(Mutex::new(std::collections::HashMap::new()));
    let selection_primary = primary.clone();
    let cluster_primary = primary.clone();
    let mut opt = usvg::Options::default();
    opt.intrinsic_size =
        Some(usvg::Size::from_wh(o.intrinsic_width as f32, o.intrinsic_height as f32).ok_or(1)?);
    opt.fontdb = Arc::new(db);
    opt.font_resolver = usvg::FontResolver {
        select_font: Box::new(move |font, db| {
            let id = font
                .families()
                .iter()
                .find_map(|family| query_family(font, &family.to_string(), db));
            let chosen = id.or_else(|| {
                family_fallback
                    .iter()
                    .find_map(|family| query_family(font, family, db))
            });
            selection_primary
                .lock()
                .unwrap()
                .insert(font_detail(font, "").to_string(), (chosen, id.is_some()));
            chosen
        }),
        select_fallback: Box::new(|_, _, _| None),
        missing_glyph: Box::new(|_| {}),
        cluster_candidates: Some(Box::new(move |font, db| {
            let mut ids = Vec::new();
            for name in font
                .families()
                .iter()
                .map(ToString::to_string)
                .chain(fallback_families.iter().cloned())
            {
                if let Some(id) = query_family(font, &name, db) {
                    if !ids.contains(&id) {
                        ids.push(id)
                    }
                }
            }
            ids
        })),
        cluster_result: Box::new(move |font, text, id| {
            let mut detail = font_detail(font, text);
            let primary = cluster_primary.lock().unwrap();
            let selection = primary.get(&font_detail(font, "").to_string());
            if let Some(id) = id {
                cluster_ids.lock().unwrap().insert(id);
                if selection.is_none_or(|(primary, exact)| !exact || *primary != Some(id)) {
                    detail["selected_family"] = cluster_faces[&id]["family"].clone();
                    cluster_warnings.lock().unwrap().push(detail)
                }
            } else {
                let code = if selection.is_none_or(|(id, _)| id.is_none()) {
                    5
                } else {
                    6
                };
                detail["status"] = json!(code);
                let mut errors = glyph_errors.lock().unwrap();
                if errors.is_empty() {
                    errors.push(Failure { code, detail })
                }
            }
        }),
    };
    let tree = usvg::Tree::from_xmltree(&doc, &opt).map_err(parse_error)?;
    if !errors.lock().unwrap().is_empty() {
        return Err(errors.lock().unwrap().remove(0));
    }
    let mut pixmap = tiny_skia::Pixmap::new(o.width, o.height).ok_or(2)?;
    let b = o.background_rgba;
    let background = tiny_skia::PremultipliedColorU8::from_rgba(
        (b >> 24) as u8,
        (b >> 16) as u8,
        (b >> 8) as u8,
        b as u8,
    )
    .ok_or(1)?;
    pixmap.pixels_mut().fill(background);
    let transform = tiny_skia::Transform::from_row(
        o.fit as f32,
        0.,
        0.,
        o.fit as f32,
        o.translate_x as f32,
        o.translate_y as f32,
    );
    if !transform.is_finite() {
        return Err(1.into());
    }
    resvg::render(&tree, transform, &mut pixmap.as_mut());
    let selected = selected.lock().unwrap();
    let manifest = metadata
        .into_iter()
        .filter(|m| {
            face_metadata
                .iter()
                .any(|(id, value)| selected.contains(id) && value == m)
        })
        .collect::<Vec<_>>();
    let mut warning_keys = HashSet::new();
    let warnings = warnings
        .lock()
        .unwrap()
        .iter()
        .filter(|w| warning_keys.insert(w.to_string()))
        .cloned()
        .collect::<Vec<_>>();
    Ok((
        pixmap.take(),
        json!({"font_manifest":manifest,"warnings":warnings}),
    ))
}
/// Free buffers using the same allocator that allocated them; zero the output.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn svgpng_v1_render_free(output: *mut RenderOutput) {
    if output.is_null() {
        return;
    }
    let out = unsafe { &mut *output };
    for (p, n) in [
        (out.pixels, out.pixels_length),
        (out.diagnostics, out.diagnostics_length),
    ] {
        if !p.is_null() {
            unsafe { drop(Box::from_raw(ptr::slice_from_raw_parts_mut(p, n))) }
        }
    }
    *out = RenderOutput::empty();
}

#[cfg(test)]
mod tests {
    use super::*;
    fn options() -> RenderOptions {
        RenderOptions {
            abi_version: 1,
            width: 2,
            height: 2,
            background_rgba: 0x00008080,
            intrinsic_width: 2.,
            intrinsic_height: 2.,
            fit: 1.,
            translate_x: 0.,
            translate_y: 0.,
        }
    }
    const NOTO: &[u8] = include_bytes!("../tests/fonts/NotoSans-Regular.ttf");
    const DEVANAGARI: &[u8] = include_bytes!("../tests/fonts/NotoSansDevanagari-Regular.ttf");
    const BOLD: &[u8] = include_bytes!("../tests/fonts/NotoSans-Bold.ttf");
    fn face(bytes: &[u8], family: &str, fallback_order: usize) -> FontInput {
        FontInput {
            bytes: bytes.as_ptr(),
            length: bytes.len(),
            requested_family: family.as_ptr(),
            family_length: family.len(),
            source_id: b"fixture".as_ptr(),
            source_id_length: 7,
            fallback_order,
        }
    }
    fn run(svg: &str, o: &RenderOptions) -> (i32, Vec<u8>, Value) {
        run_fonts(svg, o, &[])
    }
    fn run_fonts(svg: &str, o: &RenderOptions, fonts: &[FontInput]) -> (i32, Vec<u8>, Value) {
        let mut out = RenderOutput::empty();
        let code = unsafe {
            svgpng_v1_render(
                svg.as_ptr(),
                svg.len(),
                fonts.as_ptr(),
                fonts.len(),
                o,
                &mut out,
            )
        };
        let bytes = if out.pixels.is_null() {
            vec![]
        } else {
            unsafe { slice::from_raw_parts(out.pixels, out.pixels_length) }.to_vec()
        };
        let diagnostics = serde_json::from_slice(unsafe {
            slice::from_raw_parts(out.diagnostics, out.diagnostics_length)
        })
        .unwrap();
        unsafe { svgpng_v1_render_free(&mut out) };
        assert!(out.pixels.is_null());
        assert_eq!(out.diagnostics_length, 0);
        unsafe { svgpng_v1_render_free(&mut out) };
        (code, bytes, diagnostics)
    }
    #[test]
    fn renders_premultiplied_shape_and_background() {
        let (code, pixels, _) = run(
            "<svg xmlns='http://www.w3.org/2000/svg'><path fill='red' d='M0 0H1V2H0Z'/></svg>",
            &options(),
        );
        assert_eq!(code, 0);
        assert_eq!(&pixels[..4], &[255, 0, 0, 255]);
        assert_eq!(&pixels[4..8], &[0, 0, 128, 128]);
    }
    #[test]
    fn guards_original_references() {
        for svg in [
            "<svg href='file:///tmp/x'/>",
            "<!DOCTYPE svg><svg/>",
            "<svg><style>@import 'https://example.test/x';</style></svg>",
        ] {
            assert_eq!(run(svg, &options()).0, 7);
        }
    }
    #[test]
    fn limits_before_allocation() {
        let mut o = options();
        o.width = 32769;
        assert_eq!(run("<svg/>", &o).0, 2);
        o = options();
        o.fit = f64::INFINITY;
        assert_eq!(run("<svg/>", &o).0, 1);
    }
    #[test]
    fn root_attributes_preserve_decimal_text() {
        let svg = "<svg width='1.2300' height='2em' viewBox='0 0 4 5'/>";
        let mut out = RenderOutput::empty();
        assert_eq!(
            unsafe { svgpng_v1_root_attributes(svg.as_ptr(), svg.len(), &mut out) },
            0
        );
        let data: Value = serde_json::from_slice(unsafe {
            slice::from_raw_parts(out.diagnostics, out.diagnostics_length)
        })
        .unwrap();
        assert_eq!(data["width"], "1.2300");
        unsafe { svgpng_v1_render_free(&mut out) };
    }
    #[test]
    fn missing_family_is_explicit() {
        assert_eq!(
            run(
                "<svg xmlns='http://www.w3.org/2000/svg'><text x='0' y='1'>A</text></svg>",
                &options()
            )
            .0,
            5
        );
    }
    #[test]
    fn missing_named_family_diagnostics_preserve_raw_name() {
        let (code, _, detail) = run(
            "<svg xmlns='http://www.w3.org/2000/svg'><text font-family='Absent' x='0' y='1'>A</text></svg>",
            &options(),
        );
        assert_eq!(code, 5);
        assert_eq!(detail["error"]["requested_family"], "Absent");
    }
    fn text_options() -> RenderOptions {
        let mut o = options();
        o.width = 120;
        o.height = 40;
        o.intrinsic_width = 120.;
        o.intrinsic_height = 40.;
        o.background_rgba = 0;
        o
    }
    #[test]
    fn supplied_font_shapes_and_records_actual_face() {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'><text font-family='Noto Sans' x='2' y='30'>office</text></svg>";
        let (code, pixels, d) =
            run_fonts(svg, &text_options(), &[face(NOTO, "Noto Sans", usize::MAX)]);
        assert_eq!(code, 0);
        assert!(pixels.iter().any(|b| *b > 0));
        assert_eq!(d["font_manifest"].as_array().unwrap().len(), 1);
        assert_eq!(d["font_manifest"][0]["family"], "noto sans");
        assert_eq!(d["warnings"], json!([]));
    }
    #[test]
    fn whole_devanagari_cluster_fallback_matches_direct_shaping() {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'><text font-family='Noto Sans' x='2' y='30'>क्षि</text></svg>";
        let direct = svg.replace("Noto Sans'", "Noto Sans Devanagari'");
        let missing = run_fonts(svg, &text_options(), &[face(NOTO, "Noto Sans", usize::MAX)]);
        assert_eq!(missing.0, 6);
        assert_eq!(missing.2["error"]["requested_family"], "Noto Sans");
        assert!(
            missing.2["error"]["scalars"]
                .as_array()
                .unwrap()
                .contains(&json!(0x0915))
        );
        let (code, pixels, d) = run_fonts(
            svg,
            &text_options(),
            &[face(NOTO, "Noto Sans", usize::MAX), face(DEVANAGARI, "", 0)],
        );
        let control = run_fonts(
            &direct,
            &text_options(),
            &[face(DEVANAGARI, "Noto Sans Devanagari", usize::MAX)],
        );
        assert_eq!(code, 0);
        assert_eq!(control.0, 0);
        assert_eq!(pixels, control.1);
        assert_eq!(d["font_manifest"].as_array().unwrap().len(), 1);
        assert_eq!(d["font_manifest"][0]["family"], "noto sans devanagari");
        assert_eq!(
            d["warnings"][0]["scalars"],
            json!([0x0915, 0x0937, 0x093f, 0x094d])
        );
    }
    #[test]
    fn ordered_fallback_matches_requested_weight() {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'><text font-family='Absent' font-weight='700' x='2' y='30'>A</text></svg>";
        let (code, _, d) = run_fonts(
            svg,
            &text_options(),
            &[face(NOTO, "", 0), face(BOLD, "", 1)],
        );
        assert_eq!(code, 0);
        assert_eq!(d["font_manifest"][0]["weight"], 700);
        assert_eq!(d["warnings"][0]["selected_family"], "noto sans");
        assert_eq!(d["warnings"][0]["scalars"], json!([65]));
    }
    #[test]
    fn rejects_metadata_mismatch_and_duplicate_faces() {
        assert_eq!(
            run_fonts("<svg/>", &options(), &[face(NOTO, "Wrong", usize::MAX)]).0,
            3
        );
        assert_eq!(
            run_fonts(
                "<svg/>",
                &options(),
                &[
                    face(NOTO, "Noto Sans", usize::MAX),
                    face(NOTO, "Noto Sans", usize::MAX)
                ]
            )
            .0,
            4
        );
    }
    #[test]
    fn collection_face_limit_precedes_font_loading() {
        let mut bytes = b"ttcf\0\x01\0\0".to_vec();
        bytes.extend_from_slice(&65u32.to_be_bytes());
        bytes.resize(12 + 65 * 4, 0);
        assert_eq!(
            run_fonts(
                "<svg/>",
                &options(),
                &[face(&bytes, "Noto Sans", usize::MAX)]
            )
            .0,
            2
        );
    }
    #[test]
    fn concurrent_supplied_font_renders_are_isolated() {
        let render = || {
            run_fonts(
                "<svg xmlns='http://www.w3.org/2000/svg'><text font-family='Noto Sans' x='2' y='30'>office</text></svg>",
                &text_options(),
                &[face(NOTO, "Noto Sans", usize::MAX)],
            )
        };
        let expected = render();
        let jobs = (0..4)
            .map(|_| std::thread::spawn(render))
            .collect::<Vec<_>>();
        for job in jobs {
            assert_eq!(job.join().unwrap(), expected);
        }
    }
}
