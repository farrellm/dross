package main

// web.go: turn a captured URL into a self-contained page snapshot — obelisk
// inlines every resource (images, CSS) as data URIs into one HTML file, and
// go-readability extracts the article title and plain text for indexing.
// No Telegram or MCP imports here so the whole pipeline tests offline.

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os/exec"
	"path"
	"strings"
	"time"
	"unicode"

	readability "github.com/go-shiori/go-readability"
	"github.com/go-shiori/obelisk"
)

const (
	fetchTimeout     = 90 * time.Second // whole-archive budget (page + all resources)
	resourceTimeout  = 30 * time.Second // obelisk per-request timeout
	maxParallelFetch = 8                // obelisk MaxConcurrentDownload
	maxSnapshotBytes = 50 << 20         // give up on absurd pages (every attachment is git-committed)
	maxExtractBytes  = 2 << 20          // cap text fed to doc_chunks/embeddings
	fetchUserAgent   = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36 dross-bot/0.1"
)

// splitURLMessage decides whether a message is a URL capture: its first
// whitespace-separated token must be an http(s) URL. Whatever follows (same
// line or below) is returned as rest — it becomes the literature note's
// initial body. URLs buried mid-sentence stay on the plain-capture path.
func splitURLMessage(text string) (pageURL, rest string, ok bool) {
	text = strings.TrimSpace(text)
	first, remainder := text, ""
	if i := strings.IndexFunc(text, unicode.IsSpace); i >= 0 {
		first, remainder = text[:i], text[i:]
	}
	u, err := url.Parse(first)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", "", false
	}
	return first, strings.TrimSpace(remainder), true
}

// arxivID recognizes arxiv paper URLs — /abs/, /pdf/, or /html/ on any
// arxiv host — and returns the paper id (version suffix kept, trailing .pdf
// dropped). Old-style ids contain a slash (cs/0112017), so everything after
// the section prefix is the id. Captures of any form are normalized by the
// caller: snapshot https://arxiv.org/abs/<id>, download
// https://arxiv.org/pdf/<id>.
func arxivID(pageURL string) (string, bool) {
	u, err := url.Parse(pageURL)
	if err != nil {
		return "", false
	}
	switch strings.ToLower(u.Host) {
	case "arxiv.org", "www.arxiv.org", "export.arxiv.org":
	default:
		return "", false
	}
	var id string
	for _, prefix := range []string{"/abs/", "/pdf/", "/html/"} {
		if rest, ok := strings.CutPrefix(u.Path, prefix); ok {
			id = strings.TrimSuffix(rest, ".pdf")
			break
		}
	}
	id = strings.Trim(id, "/")
	if id == "" {
		return "", false
	}
	return id, true
}

// fetchFile downloads a single file (no resource inlining — that's
// fetchPage's job) with the same UA, timeout, and size budget as snapshots.
func fetchFile(ctx context.Context, fileURL string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fileURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", fetchUserAgent)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("downloading %s: %w", fileURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("downloading %s: %s", fileURL, resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxSnapshotBytes+1))
	if err != nil {
		return nil, fmt.Errorf("downloading %s: %w", fileURL, err)
	}
	if len(data) > maxSnapshotBytes {
		return nil, fmt.Errorf("downloading %s: file too large (>%d bytes)", fileURL, maxSnapshotBytes)
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("downloading %s: empty response", fileURL)
	}
	return data, nil
}

// pdfText extracts a PDF's plain text via pdftotext (poppler), capped like
// readability output. Best-effort by design: no pdftotext on PATH, or a
// broken PDF, is an error the caller may ignore.
func pdfText(ctx context.Context, pdfPath string) (string, error) {
	bin, err := exec.LookPath("pdftotext")
	if err != nil {
		return "", fmt.Errorf("pdftotext not found: %w", err)
	}
	var out bytes.Buffer
	cmd := exec.CommandContext(ctx, bin, pdfPath, "-")
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("pdftotext %s: %w", pdfPath, err)
	}
	text := strings.TrimSpace(out.String())
	if len(text) > maxExtractBytes {
		text = text[:maxExtractBytes]
	}
	return text, nil
}

type webPage struct {
	data        []byte
	contentType string
	title       string // readability title; empty for non-HTML or extraction failure
	text        string // readability plain text, capped at maxExtractBytes
}

// fetchPage archives pageURL into a single self-contained file. For HTML the
// snapshot has all resources inlined and JS stripped (a snapshot is for
// reading, not re-execution); readability then runs on the archived bytes —
// best-effort, its failure keeps the snapshot with empty title/text. Non-HTML
// roots (a direct PDF/image link) pass through as raw bytes.
func fetchPage(ctx context.Context, pageURL string) (*webPage, error) {
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()

	arc := &obelisk.Archiver{
		UserAgent:             fetchUserAgent,
		RequestTimeout:        resourceTimeout,
		MaxRetries:            1,
		MaxConcurrentDownload: maxParallelFetch,
		SkipResourceURLError:  true, // a broken <img> must not sink the archive
		DisableJS:             true,
	}
	arc.Validate()
	data, contentType, err := arc.Archive(ctx, obelisk.Request{URL: pageURL})
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("archiving %s: empty response", pageURL)
	}
	if len(data) > maxSnapshotBytes {
		return nil, fmt.Errorf("archiving %s: snapshot too large (%d bytes)", pageURL, len(data))
	}

	page := &webPage{data: data, contentType: contentType}
	if strings.HasPrefix(contentType, "text/html") {
		if u, uerr := url.Parse(pageURL); uerr == nil {
			if art, rerr := readability.FromReader(bytes.NewReader(data), u); rerr == nil {
				page.title = strings.TrimSpace(art.Title)
				page.text = strings.TrimSpace(art.TextContent)
				if len(page.text) > maxExtractBytes {
					page.text = page.text[:maxExtractBytes]
				}
			}
		}
	}
	return page, nil
}

// snapshotName picks the attach filename for a snapshot. It is user-visible:
// archive-document keeps the basename and uses it as the note's link text.
func snapshotName(title, pageURL, contentType string) string {
	slug := slugify(title)
	u, err := url.Parse(pageURL)
	if err != nil {
		u = &url.URL{}
	}
	if slug == "" {
		slug = slugify(u.Host + " " + path.Base(u.Path))
	}
	if slug == "" {
		slug = "page"
	}

	ext := ".html"
	if !strings.HasPrefix(contentType, "text/html") {
		mediaType, _, merr := mime.ParseMediaType(contentType)
		if exts, eerr := mime.ExtensionsByType(mediaType); merr == nil && eerr == nil && len(exts) > 0 {
			ext = exts[0]
		} else if e := path.Ext(u.Path); e != "" {
			ext = e
		} else {
			ext = ".bin"
		}
	}
	return slug + ext
}

// slugify mirrors the server's note-filename slugs: lowercase alphanumeric
// runs joined by single dashes, capped so filenames stay readable.
func slugify(s string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z' || r >= '0' && r <= '9':
			if dash && b.Len() > 0 {
				b.WriteByte('-')
			}
			dash = false
			b.WriteRune(r)
		default:
			dash = true
		}
		if b.Len() >= 60 {
			break
		}
	}
	return b.String()
}
