package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSplitURLMessage(t *testing.T) {
	cases := []struct {
		name      string
		text      string
		url, rest string
		ok        bool
	}{
		{"bare url", "https://example.com/a", "https://example.com/a", "", true},
		{"url with comment", "https://example.com/a worth a read", "https://example.com/a", "worth a read", true},
		{"url then body lines", "http://example.com\nnotes about it\nmore", "http://example.com", "notes about it\nmore", true},
		{"surrounding whitespace", "  https://example.com \n", "https://example.com", "", true},
		{"url mid-sentence", "check out https://example.com later", "", "", false},
		{"other scheme", "ftp://example.com/file", "", "", false},
		{"command", "/help", "", "", false},
		{"no host", "http://", "", "", false},
		{"plain text", "just a thought", "", "", false},
		{"empty", "", "", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			url, rest, ok := splitURLMessage(c.text)
			if url != c.url || rest != c.rest || ok != c.ok {
				t.Errorf("splitURLMessage(%q) = (%q, %q, %v), want (%q, %q, %v)",
					c.text, url, rest, ok, c.url, c.rest, c.ok)
			}
		})
	}
}

// A minimal valid 1x1 PNG.
var tinyPNG = []byte{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
	0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
	0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x62, 0x00, 0x01, 0x00, 0x00,
	0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
	0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
}

const testArticle = `<html><head><title>Test Page</title></head><body><article>
<h1>Test Page</h1>
<p>Readability needs a real paragraph or two of prose before it will score a
node as the article, so this test page carries several sentences of filler
about the venerable art of note taking and the perils of link rot.</p>
<p>A second paragraph seals the deal: the zettelkasten remembers what the
network forgets, and a local snapshot keeps the images alongside the words.</p>
<img src="/img.png">
</article></body></html>`

// Issue #10: readability drops anything it judges invisible, so an article
// buried in a hidden container comes back empty (or title-only) even though
// the snapshot holds the whole thing — the same shape as LessWrong's markup
// defeating it. The prose has to clear minFallbackBytes to be worth using.
var hiddenArticle = `<html><head><title>Hidden Page</title></head><body>
<div style="display:none"><h1>Hidden Page</h1><p>` +
	strings.Repeat("The zettelkasten remembers what the network forgets. ", 60) +
	`</p></div></body></html>`

func TestFetchPage(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(testArticle))
	})
	mux.HandleFunc("/hidden", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(hiddenArticle))
	})
	mux.HandleFunc("/img.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(tinyPNG)
	})
	mux.HandleFunc("/doc.pdf", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/pdf")
		_, _ = w.Write([]byte("%PDF-1.4 fake"))
	})
	// Deliberately mislabeled, the way real hosts serve papers.
	mux.HandleFunc("/paper", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		http.ServeFile(w, r, filepath.Join("testdata", "hello.pdf"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	t.Run("html with image inlined", func(t *testing.T) {
		page, err := fetchPage(context.Background(), srv.URL+"/")
		if err != nil {
			t.Fatalf("fetchPage: %v", err)
		}
		if !strings.HasPrefix(page.contentType, "text/html") {
			t.Errorf("contentType = %q, want text/html", page.contentType)
		}
		if page.title != "Test Page" {
			t.Errorf("title = %q, want %q", page.title, "Test Page")
		}
		if !strings.Contains(page.text, "link rot") {
			t.Errorf("extracted text missing body prose: %q", page.text)
		}
		if page.textFallback {
			t.Error("textFallback = true: a page readability handles must not fall back")
		}
		snap := string(page.data)
		if !strings.Contains(snap, "data:image/png;base64") {
			t.Error("snapshot does not inline the image as a data URI")
		}
		if strings.Contains(snap, `src="/img.png"`) {
			t.Error("snapshot still references the remote image")
		}
	})

	// Issue #10: a page whose extract collapsed used to be archived with a
	// title-only sidecar, invisible to search while the snapshot held the
	// article. The raw strip is the fallback.
	t.Run("failed extraction falls back to raw text", func(t *testing.T) {
		page, err := fetchPage(context.Background(), srv.URL+"/hidden")
		if err != nil {
			t.Fatalf("fetchPage: %v", err)
		}
		if !page.textFallback {
			t.Errorf("textFallback = false, want true (readability text was %q)", page.text)
		}
		if !strings.Contains(page.text, "the network forgets") {
			t.Errorf("fallback text missing the page's prose: %q", page.text)
		}
	})

	t.Run("non-html passes through raw", func(t *testing.T) {
		page, err := fetchPage(context.Background(), srv.URL+"/doc.pdf")
		if err != nil {
			t.Fatalf("fetchPage: %v", err)
		}
		if !strings.HasPrefix(page.contentType, "application/pdf") {
			t.Errorf("contentType = %q, want application/pdf", page.contentType)
		}
		if string(page.data) != "%PDF-1.4 fake" {
			t.Errorf("data = %q, want raw pass-through", page.data)
		}
		if page.title != "" || page.text != "" {
			t.Errorf("non-HTML should skip readability, got title=%q text=%q", page.title, page.text)
		}
	})

	// Issue #8: a captured PDF used to reach archive-document with no text at
	// all, so it was archived but never indexed. This walks archiveURL's chain
	// — snapshot, save, extract — on a PDF the host mislabels as octet-stream.
	t.Run("captured pdf is text-extracted", func(t *testing.T) {
		if _, err := exec.LookPath("pdftotext"); err != nil {
			t.Skip("pdftotext not installed")
		}
		page, err := fetchPage(context.Background(), srv.URL+"/paper")
		if err != nil {
			t.Fatalf("fetchPage: %v", err)
		}
		if page.text != "" {
			t.Fatalf("readability should not have run on a PDF, got %q", page.text)
		}
		saved := filepath.Join(t.TempDir(), snapshotName(page.title, srv.URL+"/paper", page.contentType))
		if err := os.WriteFile(saved, page.data, 0o644); err != nil {
			t.Fatalf("saving snapshot: %v", err)
		}
		text, isPDF := archiveText(context.Background(), saved)
		if !isPDF {
			t.Error("isPDF = false: a mislabeled PDF must still be sniffed as one")
		}
		if !strings.Contains(text, "hello dross zettelkasten") {
			t.Errorf("extracted text = %q, missing the PDF's prose", text)
		}
	})

	t.Run("timeout honored", func(t *testing.T) {
		slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(2 * time.Second)
		}))
		defer slow.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()
		if _, err := fetchPage(ctx, slow.URL); err == nil {
			t.Error("expected timeout error, got nil")
		}
	})
}

func TestHTMLText(t *testing.T) {
	const doc = `<html><head><title>T</title>
<style>body { color: red }</style>
<script>var x = "scripts are not prose";</script>
</head><body>
<noscript>enable javascript</noscript>
<h1>Heading</h1>
<p>Prose   with
collapsed   whitespace &amp; an entity.</p>
<svg><text>vector label</text></svg>
</body></html>`

	got := htmlText([]byte(doc))
	for _, want := range []string{"Heading", "Prose with collapsed whitespace & an entity."} {
		if !strings.Contains(got, want) {
			t.Errorf("htmlText missing %q, got %q", want, got)
		}
	}
	for _, unwanted := range []string{"color: red", "scripts are not prose", "enable javascript", "vector label"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("htmlText kept %q from a noise element: %q", unwanted, got)
		}
	}

	t.Run("adjacent blocks stay separate words", func(t *testing.T) {
		// Minified markup carries no whitespace between blocks; without a
		// separator the two headings fuse into one unsearchable token.
		got := htmlText([]byte(`<html><body><h1>Alpha</h1><h2>Beta</h2><p>Gamma<b>Delta</b></p></body></html>`))
		if want := "Alpha Beta Gamma Delta"; got != want {
			t.Errorf("htmlText = %q, want %q", got, want)
		}
	})

	t.Run("capped", func(t *testing.T) {
		huge := "<html><body><p>" + strings.Repeat("word ", maxExtractBytes) + "</p></body></html>"
		if n := len(htmlText([]byte(huge))); n != maxExtractBytes {
			t.Errorf("len = %d, want the %d-byte cap", n, maxExtractBytes)
		}
	})

	t.Run("garbage yields nothing useful", func(t *testing.T) {
		if got := htmlText([]byte{0xff, 0xfe, 0x00}); strings.Contains(got, "<") {
			t.Errorf("htmlText on non-HTML bytes = %q", got)
		}
	})
}

func TestPreferFallback(t *testing.T) {
	long := strings.Repeat("x", 40000)
	cases := []struct {
		name             string
		extracted, strip string
		want             bool
	}{
		// The case from issue #10: 60 chars of title against 38k of article.
		{"title only", strings.Repeat("x", 60), strings.Repeat("x", 37914), true},
		{"nothing extracted", "", strings.Repeat("x", 5000), true},
		// A short post under a long comment thread: readability's clean text
		// beats a strip full of comments.
		{"short article, heavy page", strings.Repeat("x", 1500), long, false},
		{"full article", strings.Repeat("x", 5000), long, false},
		// Nothing worth falling back to.
		{"strip is empty too", strings.Repeat("x", 60), strings.Repeat("x", 200), false},
		{"both empty", "", "", false},
		// Boundaries.
		{"strip just under the floor", "", strings.Repeat("x", minFallbackBytes-1), false},
		{"strip at the floor", "", strings.Repeat("x", minFallbackBytes), true},
		{"ratio just short", strings.Repeat("x", 500), strings.Repeat("x", 2499), false},
		{"ratio met", strings.Repeat("x", 500), strings.Repeat("x", 2500), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := preferFallback(c.extracted, c.strip); got != c.want {
				t.Errorf("preferFallback(%d chars, %d chars) = %v, want %v",
					len(c.extracted), len(c.strip), got, c.want)
			}
		})
	}
}

func TestArchiveText(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatalf("writing %s: %v", name, err)
		}
		return p
	}

	t.Run("non-pdf is not sniffed as one", func(t *testing.T) {
		// The .pdf name is deliberate: the magic number decides, not the name.
		text, isPDF := archiveText(context.Background(), write("liar.pdf", "<html>not a pdf</html>"))
		if isPDF || text != "" {
			t.Errorf("archiveText = (%q, %v), want (\"\", false)", text, isPDF)
		}
	})

	t.Run("missing file", func(t *testing.T) {
		text, isPDF := archiveText(context.Background(), filepath.Join(dir, "absent.pdf"))
		if isPDF || text != "" {
			t.Errorf("archiveText = (%q, %v), want (\"\", false)", text, isPDF)
		}
	})

	t.Run("broken pdf reports the attempt", func(t *testing.T) {
		// isPDF stays true so the caller can warn rather than archive in silence.
		text, isPDF := archiveText(context.Background(), write("broken.pdf", "%PDF-1.4 fake"))
		if !isPDF {
			t.Error("isPDF = false, want true: the PDF magic number should be recognized")
		}
		if text != "" {
			t.Errorf("text = %q, want empty for an unreadable PDF", text)
		}
	})

	t.Run("real pdf", func(t *testing.T) {
		if _, err := exec.LookPath("pdftotext"); err != nil {
			t.Skip("pdftotext not installed")
		}
		text, isPDF := archiveText(context.Background(), filepath.Join("testdata", "hello.pdf"))
		if !isPDF {
			t.Error("isPDF = false, want true")
		}
		if !strings.Contains(text, "hello dross zettelkasten") {
			t.Errorf("text = %q, missing the fixture's prose", text)
		}
	})
}

func TestArxivID(t *testing.T) {
	cases := []struct {
		name string
		url  string
		id   string
		ok   bool
	}{
		{"abs", "https://arxiv.org/abs/2401.12345", "2401.12345", true},
		{"abs with version", "https://arxiv.org/abs/2401.12345v2", "2401.12345v2", true},
		{"pdf", "https://arxiv.org/pdf/2401.12345", "2401.12345", true},
		{"pdf with extension", "https://arxiv.org/pdf/2401.12345v3.pdf", "2401.12345v3", true},
		{"html", "https://arxiv.org/html/2401.12345v1", "2401.12345v1", true},
		{"old-style id", "https://arxiv.org/abs/cs/0112017", "cs/0112017", true},
		{"old-style pdf", "https://arxiv.org/pdf/cs/0112017v1.pdf", "cs/0112017v1", true},
		{"www host", "https://www.arxiv.org/abs/2401.12345", "2401.12345", true},
		{"export host", "http://export.arxiv.org/abs/2401.12345", "2401.12345", true},
		{"trailing slash", "https://arxiv.org/abs/2401.12345/", "2401.12345", true},
		{"other arxiv page", "https://arxiv.org/list/cs.AI/recent", "", false},
		{"abs root only", "https://arxiv.org/abs/", "", false},
		{"lookalike host", "https://notarxiv.org/abs/2401.12345", "", false},
		{"unrelated url", "https://example.com/abs/2401.12345", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			id, ok := arxivID(c.url)
			if id != c.id || ok != c.ok {
				t.Errorf("arxivID(%q) = (%q, %v), want (%q, %v)", c.url, id, ok, c.id, c.ok)
			}
		})
	}
}

func TestFetchFile(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/doc.pdf", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/pdf")
		_, _ = w.Write([]byte("%PDF-1.4 fake"))
	})
	mux.HandleFunc("/huge", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(make([]byte, maxSnapshotBytes+1))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	t.Run("success", func(t *testing.T) {
		data, err := fetchFile(context.Background(), srv.URL+"/doc.pdf")
		if err != nil {
			t.Fatalf("fetchFile: %v", err)
		}
		if string(data) != "%PDF-1.4 fake" {
			t.Errorf("data = %q, want raw file bytes", data)
		}
	})

	t.Run("404", func(t *testing.T) {
		if _, err := fetchFile(context.Background(), srv.URL+"/missing"); err == nil {
			t.Error("expected error for 404, got nil")
		}
	})

	t.Run("size capped", func(t *testing.T) {
		if _, err := fetchFile(context.Background(), srv.URL+"/huge"); err == nil {
			t.Error("expected error for oversized file, got nil")
		}
	})
}

func TestSnapshotName(t *testing.T) {
	cases := []struct {
		name                    string
		title, url, contentType string
		want                    string
	}{
		{"slug from title", "A Great Article: Part 2!", "https://x.com/a", "text/html; charset=utf-8", "a-great-article-part-2.html"},
		{"fallback to host and path", "", "https://blog.example.com/posts/hello", "text/html", "blog-example-com-hello.html"},
		{"pdf extension", "Some Paper", "https://x.com/p.pdf", "application/pdf", "some-paper.pdf"},
		{"unknown type uses url ext", "data", "https://x.com/d.xyz", "application/x-mystery", "data.xyz"},
		{"everything empty", "", "https://", "text/html", "page.html"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := snapshotName(c.title, c.url, c.contentType); got != c.want {
				t.Errorf("snapshotName(%q, %q, %q) = %q, want %q", c.title, c.url, c.contentType, got, c.want)
			}
		})
	}
	t.Run("length capped", func(t *testing.T) {
		got := snapshotName(strings.Repeat("word ", 40), "https://x.com/a", "text/html")
		if len(got) > 66 { // 60-char slug + ".html" + slack
			t.Errorf("slug not capped: %d chars (%q)", len(got), got)
		}
	})
}
