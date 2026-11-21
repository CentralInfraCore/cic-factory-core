//! The Rust helper of the documentation gate (`tools/docgate/docgate.py`).
//!
//! Parses the Rust files named on the command line with `syn` and prints, as a JSON array of
//! `"path:line: what"` strings, every item without an outer doc comment (`///` or `#[doc]`):
//! fn, inherent method, struct, enum, union, trait, type alias, const, static, `macro_rules!`
//! and foreign (`extern`) fn / static, plus a missing `//!` inner doc of the file. Inline
//! modules are descended into, their items checked; impl blocks themselves, methods of a
//! `impl Trait for X` (they inherit the trait's doc), modules (their own file carries the doc)
//! and anything under `#[test]` / `#[cfg(test)]` are skipped.
//!
//! Usage: `rsdoc <file.rs> [<file.rs> ...]`

use std::process::ExitCode;
use syn::{Attribute, ImplItem, Item};

/// Whether the attributes carry an outer doc comment (`///` lines become `#[doc = "…"]`).
fn has_doc(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|a| a.path().is_ident("doc"))
}

/// Whether an item is test code: `#[test]` or `#[cfg(test)]`.
fn is_test(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|a| {
        a.path().is_ident("test")
            || (a.path().is_ident("cfg")
                && a.parse_args::<syn::Ident>()
                    .map(|i| i == "test")
                    .unwrap_or(false))
    })
}

/// The 1-based line a syntax node starts at.
fn line(span: proc_macro2::Span) -> usize {
    span.start().line
}

/// Collects the gaps of one file into `gaps`, items prefixed with their inline-module path.
struct Checker<'a> {
    /// The file the reported positions belong to.
    path: &'a str,
    /// The gaps found so far, as `path:line: what`.
    gaps: Vec<String>,
}

impl Checker<'_> {
    /// Records one gap at `span`.
    fn gap(&mut self, span: proc_macro2::Span, what: String) {
        self.gaps
            .push(format!("{}:{}: {}", self.path, line(span), what));
    }

    /// Checks a list of items; `prefix` is the inline-module path they sit in.
    fn items(&mut self, items: &[Item], prefix: &str) {
        for item in items {
            self.item(item, prefix);
        }
    }

    /// Checks one item and, for inline modules and inherent impls, what it contains.
    fn item(&mut self, item: &Item, prefix: &str) {
        let named = |kind: &str, ident: &syn::Ident| format!("{} {}{}", kind, prefix, ident);
        match item {
            Item::Fn(f) if !is_test(&f.attrs) && !has_doc(&f.attrs) => {
                self.gap(f.sig.ident.span(), named("fn", &f.sig.ident))
            }
            Item::Struct(s) if !is_test(&s.attrs) && !has_doc(&s.attrs) => {
                self.gap(s.ident.span(), named("struct", &s.ident))
            }
            Item::Enum(e) if !is_test(&e.attrs) && !has_doc(&e.attrs) => {
                self.gap(e.ident.span(), named("enum", &e.ident))
            }
            Item::Union(u) if !is_test(&u.attrs) && !has_doc(&u.attrs) => {
                self.gap(u.ident.span(), named("union", &u.ident))
            }
            Item::Trait(t) if !is_test(&t.attrs) && !has_doc(&t.attrs) => {
                self.gap(t.ident.span(), named("trait", &t.ident))
            }
            Item::Type(t) if !is_test(&t.attrs) && !has_doc(&t.attrs) => {
                self.gap(t.ident.span(), named("type", &t.ident))
            }
            Item::Const(c) if !is_test(&c.attrs) && !has_doc(&c.attrs) && c.ident != "_" => {
                self.gap(c.ident.span(), named("const", &c.ident))
            }
            Item::Static(s) if !is_test(&s.attrs) && !has_doc(&s.attrs) => {
                self.gap(s.ident.span(), named("static", &s.ident))
            }
            Item::Macro(m) if !is_test(&m.attrs) && !has_doc(&m.attrs) => {
                if let Some(ident) = &m.ident {
                    self.gap(ident.span(), named("macro", ident));
                }
            }
            Item::Mod(m) if !is_test(&m.attrs) => {
                if let Some((_, items)) = &m.content {
                    let inner = format!("{}{}::", prefix, m.ident);
                    self.items(items, &inner);
                }
            }
            Item::Impl(i) if !is_test(&i.attrs) && i.trait_.is_none() => {
                let recv = quote_type(&i.self_ty);
                for it in &i.items {
                    if let ImplItem::Fn(f) = it {
                        if !is_test(&f.attrs) && !has_doc(&f.attrs) {
                            self.gap(
                                f.sig.ident.span(),
                                format!("method {}{}::{}", prefix, recv, f.sig.ident),
                            );
                        }
                    }
                }
            }
            Item::ForeignMod(fm) if !is_test(&fm.attrs) => {
                for fi in &fm.items {
                    match fi {
                        syn::ForeignItem::Fn(f) if !has_doc(&f.attrs) => {
                            self.gap(f.sig.ident.span(), named("fn", &f.sig.ident))
                        }
                        syn::ForeignItem::Static(s) if !has_doc(&s.attrs) => {
                            self.gap(s.ident.span(), named("static", &s.ident))
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
}

/// The last path segment of an impl's self type (`Foo` for `&mut crate::a::Foo<T>`).
fn quote_type(t: &syn::Type) -> String {
    match t {
        syn::Type::Path(p) => p
            .path
            .segments
            .last()
            .map(|s| s.ident.to_string())
            .unwrap_or_default(),
        syn::Type::Reference(r) => quote_type(&r.elem),
        syn::Type::Paren(p) => quote_type(&p.elem),
        _ => String::from("?"),
    }
}

/// Checks every file named on the command line and prints the gaps as a JSON array.
fn main() -> ExitCode {
    let mut gaps: Vec<String> = Vec::new();
    for path in std::env::args().skip(1) {
        let src = match std::fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("rsdoc: {}: {}", path, e);
                return ExitCode::FAILURE;
            }
        };
        let file = match syn::parse_file(&src) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("rsdoc: {}:{}: {}", path, e.span().start().line, e);
                return ExitCode::FAILURE;
            }
        };
        if !file.attrs.iter().any(|a| a.path().is_ident("doc")) {
            gaps.push(format!("{}:1: file inner doc (//!)", path));
        }
        let mut c = Checker {
            path: &path,
            gaps: Vec::new(),
        };
        c.items(&file.items, "");
        gaps.extend(c.gaps);
    }
    match serde_json::to_string(&gaps) {
        Ok(s) => {
            println!("{}", s);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("rsdoc: {}", e);
            ExitCode::FAILURE
        }
    }
}
