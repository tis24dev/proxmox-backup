package config

import (
	"bufio"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// fallbackHelpers are every loader helper that consults MORE THAN ONE name for one
// setting. Listing them by name rather than by shape is deliberate: a helper added
// later is invisible to this test until someone names it here, and helperCoverage
// below fails when a get*WithFallback exists that this list does not carry, so the
// omission cannot be silent.
var fallbackHelpers = map[string]bool{
	"getStringWithFallback":      true,
	"getBoolWithFallback":        true,
	"getIntWithFallback":         true,
	"getStringSliceWithFallback": true,
}

// legacyAliasPair is one (winner, loser) taken from a call site, in the order the
// loader consults them.
type legacyAliasPair struct {
	first  string
	others []string
	site   string
}

// callSiteAliasPairs reads config.go and returns every multi-name lookup the loader
// performs, from the source rather than from anyone's memory of it. legacyAliases was
// hand-derived from two of the four helpers, and the other two contributed eleven
// names that AuditConfigFile then reported as "not a known variable and is ignored"
// on a file the loader reads perfectly well.
func callSiteAliasPairs(t *testing.T) []legacyAliasPair {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "config.go", nil, 0)
	if err != nil {
		t.Fatalf("parse config.go: %v", err)
	}

	var pairs []legacyAliasPair
	seenHelpers := map[string]bool{}
	inspect := func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		name := sel.Sel.Name
		if strings.HasSuffix(name, "WithFallback") {
			seenHelpers[name] = true
		}
		site := fmt.Sprintf("config.go:%d %s", fset.Position(call.Pos()).Line, name)

		// getBoolWithLegacyAlias(canonical, legacy, default) names its two keys as
		// separate arguments rather than in a slice.
		if name == "getBoolWithLegacyAlias" && len(call.Args) >= 2 {
			first, ok1 := constKeyName(file, call.Args[0])
			second, ok2 := constKeyName(file, call.Args[1])
			if ok1 && ok2 {
				pairs = append(pairs, legacyAliasPair{first: first, others: []string{second}, site: site})
			}
			return true
		}
		if !fallbackHelpers[name] || len(call.Args) == 0 {
			return true
		}
		lit, ok := call.Args[0].(*ast.CompositeLit)
		if !ok {
			return true
		}
		keys := make([]string, 0, len(lit.Elts))
		for _, elt := range lit.Elts {
			key, ok := constKeyName(file, elt)
			if !ok {
				t.Fatalf("%s: a key in the slice is neither a literal nor a package const; this test can no longer read the call site", site)
			}
			keys = append(keys, key)
		}
		if len(keys) > 1 {
			pairs = append(pairs, legacyAliasPair{first: keys[0], others: keys[1:], site: site})
		}
		return true
	}

	// getBoolWithLegacyAlias is a FORWARDER: its body calls getBoolWithFallback with
	// its own two parameters, so the names there are idents that resolve to nothing.
	// Its real call sites are read above, where the arguments are constants. Walking
	// declaration by declaration is what lets it be skipped by name, so an unreadable
	// key anywhere else still fails loudly instead of being waved through.
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok && fn.Name.Name == "getBoolWithLegacyAlias" {
			continue
		}
		ast.Inspect(decl, inspect)
	}

	for helper := range seenHelpers {
		if !fallbackHelpers[helper] {
			t.Fatalf("%s is a fallback helper this test does not read; add it to fallbackHelpers or its aliases go unchecked", helper)
		}
	}
	if len(pairs) == 0 {
		t.Fatal("no multi-name lookups found in config.go: the AST walk stopped matching the call sites")
	}
	return pairs
}

// constKeyName resolves a string literal, or a package-level const whose value is one.
func constKeyName(file *ast.File, expr ast.Expr) (string, bool) {
	switch e := expr.(type) {
	case *ast.BasicLit:
		if e.Kind != token.STRING {
			return "", false
		}
		value, err := strconv.Unquote(e.Value)
		return value, err == nil
	case *ast.Ident:
		return constValueInFile(file, e.Name)
	}
	return "", false
}

func constValueInFile(file *ast.File, name string) (string, bool) {
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.CONST {
			continue
		}
		for _, spec := range gen.Specs {
			value, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			for i, ident := range value.Names {
				if ident.Name != name || i >= len(value.Values) {
					continue
				}
				lit, ok := value.Values[i].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					return "", false
				}
				unquoted, err := strconv.Unquote(lit.Value)
				return unquoted, err == nil
			}
		}
	}
	return "", false
}

// Every name the loader consults as a stand-in for another must be registered, or the
// audit calls it unknown and tells the operator a variable it reads is ignored. The
// registry is hand-written; this derives the same list from the call sites, so a
// helper added later cannot leave an alias behind.
//
// Its reach is the helper call sites and nothing else. A fallback written by hand -
// AGE_RECIPIENT then AGE_RECIPIENTS, at config.go:690-693 - is invisible here, so that
// one is carried in legacyAliases with a comment saying why. Reading those out of the
// source would mean matching an if-shape rather than a call, which drifts on the first
// refactor; naming the limit is the honest alternative to pretending it is covered.
func TestEveryFallbackNameIsRegisteredOrInTheTemplate(t *testing.T) {
	templateScan, err := scanEnvAssignments(bufio.NewScanner(strings.NewReader(DefaultEnvTemplate())))
	if err != nil {
		t.Fatalf("scan the embedded template: %v", err)
	}

	missing := map[string]string{}
	for _, pair := range callSiteAliasPairs(t) {
		for _, name := range pair.others {
			if _, ok := legacyAliases[name]; ok {
				continue
			}
			if _, ok := templateScan.assignedAt[name]; ok {
				continue
			}
			missing[name] = pair.site
		}
	}
	if len(missing) == 0 {
		return
	}
	names := make([]string, 0, len(missing))
	for name := range missing {
		names = append(names, name)
	}
	sort.Strings(names)
	lines := make([]string, 0, len(names))
	for _, name := range names {
		lines = append(lines, fmt.Sprintf("  %s (%s)", name, missing[name]))
	}
	t.Fatalf("%d name(s) the loader reads are neither in legacyAliases nor assigned in the template, so the audit reports each as ignored:\n%s",
		len(names), strings.Join(lines, "\n"))
}

// The direction of each registered alias has to match the call site, because Wins is
// what the renderer uses to tell the operator WHICH of the two values is in effect.
// A wrong direction points them at the line that loses.
func TestRegisteredAliasesWinExactlyWhenTheCallSitePutsThemFirst(t *testing.T) {
	for _, pair := range callSiteAliasPairs(t) {
		for _, name := range pair.others {
			alias, ok := legacyAliases[name]
			if !ok {
				continue // covered by the test above
			}
			if alias.Wins {
				t.Errorf("%s: %s is registered as winning, but the call site consults %s first", pair.site, name, pair.first)
			}
			if alias.Canonical != pair.first {
				t.Errorf("%s: %s is registered against canonical %q, but the call site pairs it with %q",
					pair.site, name, alias.Canonical, pair.first)
			}
		}
		if alias, ok := legacyAliases[pair.first]; ok && !alias.Wins {
			t.Errorf("%s: %s is consulted FIRST but is registered as not winning", pair.site, pair.first)
		}
	}
}

// loaderReadNames returns every literal variable name config.go passes to a getter,
// with the line it appears on. Runtime-built names (the WEBHOOK_<name>_<field> prefixes
// BuildWebhookConfig assembles) are not literals and are not seen here; the audit has
// its own rule for those.
func loaderReadNames(t *testing.T) map[string]string {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "config.go", nil, 0)
	if err != nil {
		t.Fatalf("parse config.go: %v", err)
	}
	names := map[string]string{}
	record := func(expr ast.Expr) {
		lit, ok := expr.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			return
		}
		value, err := strconv.Unquote(lit.Value)
		if err != nil || !isEnvVariableName(value) || value != strings.ToUpper(value) {
			return
		}
		names[value] = fmt.Sprintf("config.go:%d", fset.Position(lit.Pos()).Line)
	}
	ast.Inspect(file, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || !strings.HasPrefix(sel.Sel.Name, "get") || len(call.Args) == 0 {
			return true
		}
		if lit, ok := call.Args[0].(*ast.CompositeLit); ok {
			for _, elt := range lit.Elts {
				record(elt)
			}
			return true
		}
		record(call.Args[0])
		return true
	})
	if len(names) == 0 {
		t.Fatal("no getter call sites found in config.go: the AST walk stopped matching")
	}
	return names
}

// The audit's whole premise is that "unknown" means the loader does not read it, so any
// name it reads and the audit rejects is a line telling the operator to delete working
// configuration. legacyAliases was one source of those; a variable the loader reads and
// the template never mentions is the other, and no reviewer caught that half.
//
// The remedy for a name found here is to say so in the template - a commented example
// is enough, and it is what the audit already accepts - NOT to make it an active
// assignment, which would make it Absent in every existing file and turn a clean run
// into a WARNING for every operator who never set it.
func TestEveryNameTheLoaderReadsIsAcceptedByTheAudit(t *testing.T) {
	template := DefaultEnvTemplate()
	templateScan, err := scanEnvAssignments(bufio.NewScanner(strings.NewReader(template)))
	if err != nil {
		t.Fatalf("scan the embedded template: %v", err)
	}
	documented := scanDocumentedVariables(bufio.NewScanner(strings.NewReader(template)))

	rejected := map[string]string{}
	for name, site := range loaderReadNames(t) {
		if _, ok := legacyAliases[name]; ok {
			continue
		}
		if _, known := templateKnows(name, templateScan.assignedAt, documented); known {
			continue
		}
		rejected[name] = site
	}
	if len(rejected) == 0 {
		return
	}
	names := make([]string, 0, len(rejected))
	for name := range rejected {
		names = append(names, name)
	}
	sort.Strings(names)
	lines := make([]string, 0, len(names))
	for _, name := range names {
		lines = append(lines, fmt.Sprintf("  %s (%s)", name, rejected[name]))
	}
	t.Fatalf("%d name(s) the loader reads are rejected by the audit, which reports each as %q:\n%s",
		len(names), "not a known variable and is ignored", strings.Join(lines, "\n"))
}
