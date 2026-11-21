// Command godoc is the Go helper of the documentation gate (tools/docgate/docgate.py).
//
// It parses the Go files named on the command line with go/parser (standard library
// only, nothing is type checked) and prints, as a JSON array of "path:line: what"
// strings, every top-level declaration without a doc comment: funcs, methods, types,
// vars and consts (inside a parenthesized group each spec needs its own comment; a
// lone spec may use the declaration's), plus every package (directory and package
// name) none of whose files carries a package doc. Directive-only comments such as
// //go:embed or //export do not count as documentation. Blank identifiers are skipped.
//
// Usage: godoc <file.go> [<file.go> ...], or the paths on stdin, one per line, when no
// argument is given (docgate passes every file in one run, so a package's files are
// never split between runs and its package doc is never reported missing by mistake).
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// documented reports whether a comment group holds any documentation text
// (directives such as //go:embed are not text).
func documented(g *ast.CommentGroup) bool {
	return g != nil && strings.TrimSpace(g.Text()) != ""
}

// pkgKey identifies one package: its directory and its declared name.
type pkgKey struct{ dir, name string }

// pkgState records, for one package, whether any file has a package doc and
// which file to report a missing one at.
type pkgState struct {
	documented bool
	first      string
}

// recvName returns the base type name of a method receiver, without pointer,
// parentheses or type parameters.
func recvName(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.StarExpr:
		return recvName(x.X)
	case *ast.ParenExpr:
		return recvName(x.X)
	case *ast.IndexExpr:
		return recvName(x.X)
	case *ast.IndexListExpr:
		return recvName(x.X)
	case *ast.Ident:
		return x.Name
	}
	return ""
}

// inputPaths returns the files to check: the arguments, or the non-empty lines of stdin.
func inputPaths() []string {
	if len(os.Args) > 1 {
		return os.Args[1:]
	}
	var paths []string
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		if p := strings.TrimSpace(sc.Text()); p != "" {
			paths = append(paths, p)
		}
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "godoc: reading stdin: %v\n", err)
		os.Exit(1)
	}
	return paths
}

// main checks every input file and prints the gaps as JSON.
func main() {
	gaps := []string{}
	pkgs := map[pkgKey]*pkgState{}
	fset := token.NewFileSet()
	for _, path := range inputPaths() {
		f, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
		if err != nil {
			fmt.Fprintf(os.Stderr, "godoc: %v\n", err)
			os.Exit(1)
		}
		key := pkgKey{filepath.Dir(path), f.Name.Name}
		st := pkgs[key]
		if st == nil {
			st = &pkgState{first: path}
			pkgs[key] = st
		}
		if documented(f.Doc) {
			st.documented = true
		}
		at := func(p token.Pos) int { return fset.Position(p).Line }
		for _, d := range f.Decls {
			switch x := d.(type) {
			case *ast.FuncDecl:
				if documented(x.Doc) {
					continue
				}
				what := "func " + x.Name.Name
				if x.Recv != nil && len(x.Recv.List) > 0 {
					what = "method " + recvName(x.Recv.List[0].Type) + "." + x.Name.Name
				}
				gaps = append(gaps, fmt.Sprintf("%s:%d: %s", path, at(x.Pos()), what))
			case *ast.GenDecl:
				if x.Tok == token.IMPORT {
					continue
				}
				grouped := x.Lparen.IsValid()
				for _, s := range x.Specs {
					var doc *ast.CommentGroup
					var names []*ast.Ident
					switch sp := s.(type) {
					case *ast.TypeSpec:
						doc, names = sp.Doc, []*ast.Ident{sp.Name}
					case *ast.ValueSpec:
						doc, names = sp.Doc, sp.Names
					}
					if !grouped && !documented(doc) {
						doc = x.Doc
					}
					if documented(doc) {
						continue
					}
					for _, n := range names {
						if n.Name == "_" {
							continue
						}
						gaps = append(gaps, fmt.Sprintf("%s:%d: %s %s", path, at(n.Pos()), x.Tok, n.Name))
					}
				}
			}
		}
	}
	keys := make([]pkgKey, 0, len(pkgs))
	for k := range pkgs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].dir != keys[j].dir {
			return keys[i].dir < keys[j].dir
		}
		return keys[i].name < keys[j].name
	})
	for _, k := range keys {
		if !pkgs[k].documented {
			gaps = append(gaps, fmt.Sprintf("%s:1: package doc (%s, %s)", pkgs[k].first, k.name, k.dir))
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(gaps); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
