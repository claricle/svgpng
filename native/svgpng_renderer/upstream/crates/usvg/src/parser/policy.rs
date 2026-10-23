//! Claricle embedding policy. Runs before conversion, including unused definitions.
use super::Error;
use cssparser::{ParseErrorKind, Parser, ParserInput, Token};

const SVG_LIMIT: usize = 16 * 1024 * 1024;
const REFERENCE_LIMIT: usize = 256 * 1024 * 1024;
const NESTING_LIMIT: usize = 128;

// Budgets belong to this parse, never to process-global resolver state.
struct Budget { decoded: usize }

pub fn guarded_document(text: &str) -> Result<roxmltree::Document<'_>, Error> {
    document(text, &mut Budget { decoded: 0 }, 0)
}

fn document<'a>(text: &'a str, budget: &mut Budget, depth: usize) -> Result<roxmltree::Document<'a>, Error> {
    if text.len() > SVG_LIMIT || depth > NESTING_LIMIT { return Err(Error::ReferenceLimit); }
    let doc = roxmltree::Document::parse_with_options(text, roxmltree::ParsingOptions {
        allow_dtd: false, ..Default::default()
    }).map_err(|e| match e {
        roxmltree::Error::DtdDetected => Error::ForbiddenReferenceAt { reference_class: "doctype", location: "document@doctype" },
        _ => Error::ParsingFailed(e),
    })?;
    inspect_document(&doc, budget, depth)?;
    Ok(doc)
}

pub fn check_document(doc: &roxmltree::Document) -> Result<(), Error> {
    inspect_document(doc, &mut Budget { decoded: 0 }, 0)
}

fn inspect_document(doc: &roxmltree::Document, budget: &mut Budget, depth: usize) -> Result<(), Error> {
    for node in doc.descendants().filter(|n| n.is_element()) {
        for a in node.attributes() {
            if a.name() == "href" || a.name() == "src" {
                let location = match node.tag_name().name() {
                    "image" => "image@href", "use" => "use@href",
                    "feImage" => "feImage@href", "svg" => "svg@href",
                    _ => "attribute@url",
                };
                check_uri_at(a.value(), budget, depth, location)?;
            }
            css(a.value(), budget, depth)?;
        }
        if node.tag_name().name() == "style" {
            for n in node.children().filter(|n| n.is_text()) { css_at(n.text().unwrap_or(""), budget, depth, "style@url")?; }
        }
    }
    Ok(())
}

fn check_uri(value: &str, budget: &mut Budget, depth: usize) -> Result<(), Error> {
    check_uri_at(value, budget, depth, "attribute@url")
}

fn check_uri_at(value: &str, budget: &mut Budget, depth: usize, location: &'static str) -> Result<(), Error> {
    let value = value.trim();
    if value.starts_with('#') && value.len() > 1 { return Ok(()); }
    if !value.starts_with("data:") {
        let lower = value.to_ascii_lowercase();
        let reference_class = if lower.starts_with("file:") { "file" }
            else if lower.starts_with("http:") || lower.starts_with("https:") || lower.starts_with("//") { "network" }
            else if lower.starts_with('/') { "absolute" }
            else if lower.contains(':') { "scheme" } else { "relative" };
        return Err(Error::ForbiddenReferenceAt { reference_class, location });
    }
    let url = data_url::DataUrl::process(value).map_err(|_| Error::MalformedReference)?;
    let (bytes, _) = url.decode_to_vec().map_err(|_| Error::MalformedReference)?;
    budget.decoded = budget.decoded.checked_add(bytes.len()).ok_or(Error::ReferenceLimit)?;
    if budget.decoded > REFERENCE_LIMIT { return Err(Error::ReferenceLimit); }
    let mime = url.mime_type();
    let looks_like_xml = bytes.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b'<');
    if (mime.type_ == "image" && mime.subtype == "svg+xml") || looks_like_xml {
        let text = std::str::from_utf8(&bytes).map_err(|_| Error::NotAnUtf8Str)?;
        document(text, budget, depth + 1)?;
    }
    Ok(())
}

pub fn check_css(text: &str) -> Result<(), Error> {
    css(text, &mut Budget { decoded: 0 }, 0)
}

fn css(text: &str, budget: &mut Budget, depth: usize) -> Result<(), Error> {
    css_at(text, budget, depth, "attribute@url")
}

fn css_at(text: &str, budget: &mut Budget, depth: usize, location: &'static str) -> Result<(), Error> {
    tokens(&mut Parser::new(&mut ParserInput::new(text)), budget, depth, location)
}

fn tokens(p: &mut Parser<'_, '_>, budget: &mut Budget, depth: usize, location: &'static str) -> Result<(), Error> {
    if depth > NESTING_LIMIT { return Err(Error::ReferenceLimit); }
    while let Ok(token) = p.next_including_whitespace_and_comments().cloned() {
        match token {
            Token::AtKeyword(ref name) if name.eq_ignore_ascii_case("import") => return Err(Error::ForbiddenReferenceAt { reference_class: "css_import", location: "style@import" }),
            Token::UnquotedUrl(ref value) => check_uri_at(value, budget, depth, location)?,
            Token::BadUrl(_) => return Err(Error::MalformedReference),
            Token::Function(ref name) if name.eq_ignore_ascii_case("url") => {
                p.parse_nested_block(|p| {
                    let value = p.expect_string()?.to_string();
                    check_uri_at(&value, budget, depth, location).map_err(|e| p.new_custom_error(e))?;
                    p.expect_exhausted()?;
                    Ok(())
                }).map_err(css_error)?;
            }
            Token::Function(_) | Token::ParenthesisBlock | Token::SquareBracketBlock | Token::CurlyBracketBlock => {
                p.parse_nested_block(|p| tokens(p, budget, depth + 1, location).map_err(|e| p.new_custom_error(e)))
                    .map_err(css_error)?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn css_error(e: cssparser::ParseError<'_, Error>) -> Error {
    match e.kind { ParseErrorKind::Custom(e) => e, _ => Error::MalformedReference }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn guards_original_xml() {
        for s in ["<svg href='file:///tmp/x'/>", "<svg style='fill:u\\72l(https://x)'/>", "<!DOCTYPE svg><svg/>", "<svg><style>@\\69mport 'x';</style></svg>", "<svg><defs><image href='https://x'/></defs></svg>", "<svg href='#safe' xmlns:xlink='http://www.w3.org/1999/xlink' xlink:href='file:///x'/>"] {
            assert!(matches!(guarded_document(s), Err(Error::ForbiddenReferenceAt { .. })), "{s}");
        }
        assert!(guarded_document("<svg><!-- <!DOCTYPE svg> --><use href='#x'/></svg>").is_ok());
    }
    #[test] fn reports_sanitized_reference_details() {
        assert!(matches!(guarded_document("<svg><image href='https://host/private'/></svg>"),
            Err(Error::ForbiddenReferenceAt { reference_class: "network", location: "image@href" })));
        assert!(matches!(guarded_document("<!DOCTYPE svg><svg/>"),
            Err(Error::ForbiddenReferenceAt { reference_class: "doctype", location: "document@doctype" })));
        assert!(matches!(guarded_document("<svg><style>rect{fill:url(file:///private)}</style></svg>"),
            Err(Error::ForbiddenReferenceAt { reference_class: "file", location: "style@url" })));
    }
    #[test] fn preserves_nested_error_classes() {
        assert!(matches!(guarded_document("<svg style='fill:var(--x,url(https://x))'/>"), Err(Error::ForbiddenReferenceAt { .. })));
        assert!(matches!(guarded_document("<svg href='data:image/svg+xml,%3Csvg%20href=%22file:///secret%22/%3E'/>"), Err(Error::ForbiddenReferenceAt { .. })));
        assert!(matches!(guarded_document("<svg href='data:image/png;base64,!'/>"), Err(Error::MalformedReference)));
        assert!(guarded_document("<svg href='data:image/svg+xml,%3Csvg/%3E'/>").is_ok());
    }
    #[test] fn bounds_parser_recursion_and_resets_budget() {
        let css = format!("{}url(#safe){}", "f(".repeat(130), ")".repeat(130));
        assert!(matches!(check_css(&css), Err(Error::ReferenceLimit)));
        let mut budget = Budget { decoded: REFERENCE_LIMIT };
        assert!(matches!(check_uri("data:image/png;base64,YQ==", &mut budget, 0), Err(Error::ReferenceLimit)));
        assert!(guarded_document("<svg href='data:image/png;base64,YQ=='/>").is_ok());
    }
}
