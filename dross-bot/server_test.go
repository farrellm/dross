package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

// fakeTools records the calls the routes make and replays canned results,
// so handler behaviour is testable without a dross-mcp subprocess.
type fakeTools struct {
	results map[string]string
	errs    map[string]error
	calls   []call
}

type call struct {
	name string
	args map[string]any
}

func (f *fakeTools) CallTool(name string, args map[string]any) (string, error) {
	f.calls = append(f.calls, call{name, args})
	if err, ok := f.errs[name]; ok {
		return "", err
	}
	if out, ok := f.results[name]; ok {
		return out, nil
	}
	return "null", nil
}

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestNoteRouteCombinesBothLinkDirections(t *testing.T) {
	f := &fakeTools{results: map[string]string{
		"read-note":     `{"id":"abc","title":"A note","raw":"* one\n"}`,
		"backlinks":     `[{"id":"b1","title":"Points here","file":"/n/b1.org","description":null}]`,
		"forward-links": `[{"id":"f1","title":null,"file":null,"description":"dangling"}]`,
	}}
	s := &webServer{mcp: f}

	rec := get(t, s.routes(), "/api/note/abc")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}

	var got struct {
		Note         map[string]any   `json:"note"`
		Backlinks    []map[string]any `json:"backlinks"`
		ForwardLinks []map[string]any `json:"forwardLinks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decoding %s: %v", rec.Body, err)
	}
	if got.Note["title"] != "A note" {
		t.Errorf("note title = %v", got.Note["title"])
	}
	if len(got.Backlinks) != 1 || got.Backlinks[0]["id"] != "b1" {
		t.Errorf("backlinks = %v", got.Backlinks)
	}
	// Dangling forward links keep their null title — the reader renders
	// them as "no note behind this ID" rather than dropping them.
	if len(got.ForwardLinks) != 1 || got.ForwardLinks[0]["title"] != nil {
		t.Errorf("forwardLinks = %v", got.ForwardLinks)
	}

	// The note view must ask for raw org: the indexed body has had its
	// headline stars stripped and cannot be rendered as an outline.
	if len(f.calls) != 3 || f.calls[0].name != "read-note" || f.calls[0].args["raw"] != true {
		t.Errorf("calls = %+v", f.calls)
	}
}

func TestToolErrorsMapToStatus(t *testing.T) {
	cases := []struct {
		name string
		path string
		tool string
		err  error
		want int
	}{
		{"missing note", "/api/note/nope", "read-note",
			errors.New("read-note: no note with ID nope"), http.StatusNotFound},
		{"embeddings off", "/api/semantic-search?q=x", "semantic-search",
			errors.New("semantic-search: semantic-search is disabled: set VOYAGE_API_KEY and restart the server"),
			http.StatusServiceUnavailable},
		{"transport down", "/api/search?q=x", "search",
			errors.New("reading from dross-mcp: EOF"), http.StatusBadGateway},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := &webServer{mcp: &fakeTools{errs: map[string]error{tc.tool: tc.err}}}
			rec := get(t, s.routes(), tc.path)
			if rec.Code != tc.want {
				t.Errorf("status = %d, want %d", rec.Code, tc.want)
			}
			var body struct {
				Error string `json:"error"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("decoding %s: %v", rec.Body, err)
			}
			if body.Error != tc.err.Error() {
				t.Errorf("error = %q, want %q", body.Error, tc.err)
			}
		})
	}
}

func TestRoutesPassArguments(t *testing.T) {
	cases := []struct {
		path string
		want call
	}{
		{"/api/notes", call{"recent-notes", map[string]any{"days": browseDays, "limit": browseLimit}}},
		{"/api/notes?limit=5", call{"recent-notes", map[string]any{"days": browseDays, "limit": 5}}},
		{"/api/notes/recent", call{"recent-notes", map[string]any{"days": 7, "limit": 50}}},
		{"/api/notes/recent?days=30", call{"recent-notes", map[string]any{"days": 30, "limit": 50}}},
		{"/api/search?q=low+rank", call{"search", map[string]any{"query": "low rank", "limit": 20}}},
		{"/api/semantic-search?q=why&limit=3", call{"semantic-search", map[string]any{"query": "why", "limit": 3}}},
		{"/api/similar/abc", call{"similar-notes", map[string]any{"id": "abc", "limit": 10}}},
		{"/api/neighborhood/abc?depth=3", call{"neighborhood", map[string]any{"id": "abc", "depth": 3}}},
		{"/api/graph", call{"graph", map[string]any{}}},
		{"/api/graph?tag=literature", call{"graph", map[string]any{"tag": "literature"}}},
		// A junk limit falls back to the default rather than erroring.
		{"/api/search?q=x&limit=many", call{"search", map[string]any{"query": "x", "limit": 20}}},
	}
	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			f := &fakeTools{}
			rec := get(t, (&webServer{mcp: f}).routes(), tc.path)
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d: %s", rec.Code, rec.Body)
			}
			if len(f.calls) != 1 || !reflect.DeepEqual(f.calls[0], tc.want) {
				t.Errorf("calls = %+v, want %+v", f.calls, tc.want)
			}
		})
	}
}

func TestResolveAttach(t *testing.T) {
	notes := t.TempDir()
	outside := t.TempDir()

	mustWrite(t, filepath.Join(notes, "inbox.org"), "* entry")
	mustWrite(t, filepath.Join(notes, "data", "ab", "cd"), "paper.pdf", "%PDF")
	mustWrite(t, filepath.Join(outside), "secret", "ssh key")
	if err := os.Symlink(filepath.Join(outside, "secret"), filepath.Join(notes, "escape")); err != nil {
		t.Skipf("symlinks unavailable on %s: %v", runtime.GOOS, err)
	}

	ok := []struct{ name, rel, want string }{
		{"file at the root", "inbox.org", filepath.Join(notes, "inbox.org")},
		{"attachment", "data/ab/cd/paper.pdf", filepath.Join(notes, "data", "ab", "cd", "paper.pdf")},
		{"redundant segments", "./data/ab/../ab/cd/paper.pdf", filepath.Join(notes, "data", "ab", "cd", "paper.pdf")},
	}
	for _, tc := range ok {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveAttach(notes, tc.rel)
			if err != nil {
				t.Fatalf("resolveAttach(%q) = %v", tc.rel, err)
			}
			// The notes dir itself may be behind a symlink (/tmp on macOS),
			// so compare against the resolved root.
			want, _ := filepath.EvalSymlinks(tc.want)
			if got != want {
				t.Errorf("got %q, want %q", got, want)
			}
		})
	}

	bad := []struct{ name, rel string }{
		{"empty", ""},
		{"traversal", "../secret"},
		{"deep traversal", "data/../../secret"},
		{"absolute path", filepath.Join(outside, "secret")},
		{"symlink out of the tree", "escape"},
		{"missing file", "nope.org"},
		{"a directory", "data/ab"},
	}
	for _, tc := range bad {
		t.Run(tc.name, func(t *testing.T) {
			if got, err := resolveAttach(notes, tc.rel); err == nil {
				t.Errorf("resolveAttach(%q) = %q, want an error", tc.rel, got)
			}
		})
	}
}

func TestStaticFallsBackToIndex(t *testing.T) {
	dist := t.TempDir()
	mustWrite(t, dist, "index.html", "<title>Dross</title>")
	mustWrite(t, filepath.Join(dist, "assets"), "app-abc123.js", "console.log(1)")
	s := &webServer{mcp: &fakeTools{}, dist: dist}
	h := s.routes()

	// A client-side route survives a reload.
	rec := get(t, h, "/note/some-uuid")
	if rec.Code != http.StatusOK || rec.Body.String() != "<title>Dross</title>" {
		t.Errorf("SPA fallback: %d %q", rec.Code, rec.Body)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Errorf("index Cache-Control = %q", cc)
	}

	rec = get(t, h, "/assets/app-abc123.js")
	if rec.Code != http.StatusOK || rec.Body.String() != "console.log(1)" {
		t.Errorf("asset: %d %q", rec.Code, rec.Body)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "public, max-age=31536000, immutable" {
		t.Errorf("asset Cache-Control = %q", cc)
	}

	// ServeMux normalizes a traversing path into a redirect before any
	// handler runs, so reach past it and hand the handler a path the mux
	// would never pass through. Nothing outside dist may come back.
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.URL.Path = "/../../etc/passwd"
	rec = httptest.NewRecorder()
	s.handleStatic(rec, req)
	if rec.Code == http.StatusOK {
		t.Errorf("traversal served %d %q", rec.Code, rec.Body)
	}
}

// mustWrite writes a file, creating parents. Path segments are joined, so
// mustWrite(t, dir, "a", "b", contents) writes dir/a/b.
func mustWrite(t *testing.T, parts ...string) {
	t.Helper()
	path := filepath.Join(parts[:len(parts)-1]...)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(parts[len(parts)-1]), 0o644); err != nil {
		t.Fatal(err)
	}
}
