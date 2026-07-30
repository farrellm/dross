package main

// server.go: the read-only HTTP backend for the web reader (../dross-web).
// It is an MCP client like everything else here — every route is a thin
// proxy onto a dross-mcp tool, so the index stays the only way in and no
// write surface is exposed on a network port. Off unless DROSS_WEB_ADDR is
// set; the perimeter is the tailnet, not the app (CONCEPT.md: single user,
// no auth model).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	// The reader loads a whole note plus both link directions in one
	// request, and every tool call re-hashes the notes tree first, so
	// requests are slow-ish by design. Generous, not unbounded.
	webReadHeaderTimeout = 10 * time.Second
	webWriteTimeout      = 120 * time.Second
	webShutdownGrace     = 5 * time.Second

	// recent-notes is also the browse list: a window wide enough to mean
	// "everything", since there is no list-all tool and this is the query
	// one would write anyway.
	browseDays  = 36500
	browseLimit = 2000
)

// toolCaller is the slice of mcpClient the routes need — an interface so
// the handlers can be tested without a dross-mcp subprocess.
type toolCaller interface {
	CallTool(name string, args map[string]any) (string, error)
}

type webServer struct {
	mcp      toolCaller
	notesDir string
	dist     string // built frontend; empty disables static serving
}

// startWeb brings up the HTTP server if DROSS_WEB_ADDR is set, and returns
// a function that shuts it down. The web server gets its own dross-mcp
// subprocess: mcp.go serializes every call behind one mutex, so sharing the
// bot's client would let a page load stall a Telegram capture.
func startWeb(ctx context.Context, mcpBin, notesDir string) func() {
	addr := os.Getenv("DROSS_WEB_ADDR")
	if addr == "" {
		return func() {}
	}

	dist := os.Getenv("DROSS_WEB_DIST")
	if dist == "" {
		dist = "../dross-web/dist"
	}
	if abs, err := filepath.Abs(dist); err == nil {
		dist = abs
	}
	if _, err := os.Stat(filepath.Join(dist, "index.html")); err != nil {
		log.Printf("web: no index.html under %s — serving the API only (run `make web-build`)", dist)
		dist = ""
	}

	c := newMcpClient(mcpBin, notesDir)
	if err := c.Start(); err != nil {
		log.Printf("web: not starting — %v", err)
		return func() {}
	}

	s := &webServer{mcp: c, notesDir: notesDir, dist: dist}
	srv := &http.Server{
		Addr:              addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: webReadHeaderTimeout,
		WriteTimeout:      webWriteTimeout,
	}

	go func() {
		log.Printf("web: listening on %s", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("web: %v", err)
		}
	}()

	return func() {
		shutCtx, cancel := context.WithTimeout(context.Background(), webShutdownGrace)
		defer cancel()
		srv.Shutdown(shutCtx)
		c.mu.Lock()
		c.stop()
		c.mu.Unlock()
	}
}

// runWeb serves the reader on its own, without the Telegram bot — the dev
// loop, and the way to run the reader without a bot token. Blocks until
// interrupted.
func runWeb() {
	notesDir := os.Getenv("DROSS_NOTES_DIR")
	if notesDir == "" {
		log.Fatal("DROSS_NOTES_DIR is not set")
	}
	mcpBin := os.Getenv("DROSS_MCP_BIN")
	if mcpBin == "" {
		mcpBin = "dross-mcp"
	}
	if os.Getenv("DROSS_WEB_ADDR") == "" {
		log.Fatal("DROSS_WEB_ADDR is not set (e.g. :8181)")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	stop := startWeb(ctx, mcpBin, notesDir)
	<-ctx.Done()
	stop()
}

func (s *webServer) routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, `{"ok":true}`)
	})
	mux.HandleFunc("GET /api/notes", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, "recent-notes", map[string]any{
			"days":  browseDays,
			"limit": intParam(r, "limit", browseLimit),
		})
	})
	mux.HandleFunc("GET /api/notes/recent", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, "recent-notes", map[string]any{
			"days":  intParam(r, "days", 7),
			"limit": intParam(r, "limit", 50),
		})
	})
	mux.HandleFunc("GET /api/note/{id}", s.handleNote)
	mux.HandleFunc("GET /api/search", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, "search", map[string]any{
			"query": r.URL.Query().Get("q"),
			"limit": intParam(r, "limit", 20),
		})
	})
	mux.HandleFunc("GET /api/semantic-search", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, "semantic-search", map[string]any{
			"query": r.URL.Query().Get("q"),
			"limit": intParam(r, "limit", 20),
		})
	})
	mux.HandleFunc("GET /api/similar/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, "similar-notes", map[string]any{
			"id":    r.PathValue("id"),
			"limit": intParam(r, "limit", 10),
		})
	})
	mux.HandleFunc("GET /api/neighborhood/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, "neighborhood", map[string]any{
			"id":    r.PathValue("id"),
			"depth": intParam(r, "depth", 2),
		})
	})
	mux.HandleFunc("GET /api/graph", func(w http.ResponseWriter, r *http.Request) {
		args := map[string]any{}
		if tag := r.URL.Query().Get("tag"); tag != "" {
			args["tag"] = tag
		}
		s.proxy(w, "graph", args)
	})
	mux.HandleFunc("GET /api/attach/{path...}", s.handleAttach)

	mux.HandleFunc("/", s.handleStatic)
	return mux
}

// proxy forwards one tool call. CallTool hands back the tool's JSON as a
// string (the MCP envelope stringifies it), so the happy path is a byte
// copy rather than a decode/re-encode round trip.
func (s *webServer) proxy(w http.ResponseWriter, name string, args map[string]any) {
	out, err := s.mcp.CallTool(name, args)
	if err != nil {
		writeToolError(w, err)
		return
	}
	writeJSON(w, out)
}

// handleNote answers the whole note view in one request: the note itself
// plus both link directions. Three tool calls means three index sweeps
// (refreshIndex runs at the top of every call), so they are worth paying
// for once per navigation rather than once per component.
func (s *webServer) handleNote(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	note, err := s.mcp.CallTool("read-note", map[string]any{"id": id, "raw": true})
	if err != nil {
		writeToolError(w, err)
		return
	}
	back, err := s.mcp.CallTool("backlinks", map[string]any{"id": id})
	if err != nil {
		writeToolError(w, err)
		return
	}
	fwd, err := s.mcp.CallTool("forward-links", map[string]any{"id": id})
	if err != nil {
		writeToolError(w, err)
		return
	}

	body, err := json.Marshal(struct {
		Note         json.RawMessage `json:"note"`
		Backlinks    json.RawMessage `json:"backlinks"`
		ForwardLinks json.RawMessage `json:"forwardLinks"`
	}{json.RawMessage(note), json.RawMessage(back), json.RawMessage(fwd)})
	if err != nil {
		writeToolError(w, err)
		return
	}
	writeJSON(w, string(body))
}

// handleAttach serves a file from the notes tree, so `[[file:data/...]]`
// links in a note resolve to the archived image or PDF.
func (s *webServer) handleAttach(w http.ResponseWriter, r *http.Request) {
	path, err := resolveAttach(s.notesDir, r.PathValue("path"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	http.ServeFile(w, r, path)
}

// resolveAttach maps a notes-relative attachment path to an absolute path
// inside the notes directory. The only place a request touches the
// filesystem, so it is a containment check, not just hygiene: Clean against
// a leading slash drops any "..", and both ends are symlink-resolved before
// comparison so a link inside the tree cannot point out of it.
func resolveAttach(notesDir, rel string) (string, error) {
	if rel == "" {
		return "", errors.New("empty path")
	}
	root, err := filepath.EvalSymlinks(notesDir)
	if err != nil {
		return "", err
	}
	candidate := filepath.Join(root, filepath.Clean("/"+rel))
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", err
	}
	if resolved != root && !strings.HasPrefix(resolved, root+string(os.PathSeparator)) {
		return "", fmt.Errorf("%s escapes the notes directory", rel)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%s is not a regular file", rel)
	}
	return resolved, nil
}

// handleStatic serves the built frontend, falling back to index.html so
// client-side routes survive a reload.
func (s *webServer) handleStatic(w http.ResponseWriter, r *http.Request) {
	if s.dist == "" {
		http.NotFound(w, r)
		return
	}
	clean := filepath.Clean("/" + r.URL.Path)
	if path := filepath.Join(s.dist, clean); clean != "/" {
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
			// Vite fingerprints everything under /assets, so it can be
			// cached hard; index.html must not be.
			if strings.HasPrefix(clean, "/assets/") {
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			}
			http.ServeFile(w, r, path)
			return
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	http.ServeFile(w, r, filepath.Join(s.dist, "index.html"))
}

func writeJSON(w http.ResponseWriter, body string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write([]byte(body))
}

// writeToolError translates a tool failure into a status the reader can act
// on. Tool errors are plain English, so matching on them is the only signal
// available — the MCP envelope carries no error codes.
func writeToolError(w http.ResponseWriter, err error) {
	msg := err.Error()
	status := http.StatusBadGateway
	switch {
	case strings.Contains(msg, "no note with ID"):
		status = http.StatusNotFound
	case strings.Contains(msg, "is disabled:"):
		status = http.StatusServiceUnavailable
	}
	log.Printf("web: %v", err)
	body, _ := json.Marshal(struct {
		Error string `json:"error"`
	}{msg})
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	w.Write(body)
}

func intParam(r *http.Request, name string, def int) int {
	if v, err := strconv.Atoi(r.URL.Query().Get(name)); err == nil {
		return v
	}
	return def
}
