package main

// dross-bot: Telegram frontend for Dross (CONCEPT.md, roadmap phases 2+4).
// Inbound: text/forwards are appended to the inbox via the MCP server's
// capture tool (with "connects to" nudges from similar-notes); messages
// leading with a URL are snapshotted (web.go) and archived, like photos
// and files, via archive-document. Outbound: one-shot
// `send` and `propose <branch>` modes for the scheduled proactive jobs
// (../proactive/), and inline Approve/Reject buttons on proposals handled
// here via git in the notes repo.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

type app struct {
	mcp      *mcpClient
	notesDir string
	allowed  map[int64]bool // empty = unconfigured: refuse and tell the sender their chat ID
}

func main() {
	log.SetFlags(log.LstdFlags)
	log.SetPrefix("dross-bot: ")

	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "send":
			runSend()
		case "propose":
			if len(os.Args) != 3 {
				log.Fatal("usage: dross-bot propose <proposal-branch>")
			}
			runPropose(os.Args[2])
		default:
			log.Fatalf("unknown command %q (send, propose, or no arguments to serve)", os.Args[1])
		}
		return
	}
	serve()
}

func serve() {
	token := os.Getenv("TELEGRAM_TOKEN")
	if token == "" {
		log.Fatal("TELEGRAM_TOKEN is not set")
	}
	notesDir := os.Getenv("DROSS_NOTES_DIR")
	if notesDir == "" {
		log.Fatal("DROSS_NOTES_DIR is not set")
	}
	mcpBin := os.Getenv("DROSS_MCP_BIN")
	if mcpBin == "" {
		mcpBin = "dross-mcp"
	}

	allowed := map[int64]bool{}
	for _, id := range parseChatIDs(os.Getenv("DROSS_TELEGRAM_CHAT_ID")) {
		allowed[id] = true
	}
	if len(allowed) == 0 {
		log.Print("DROSS_TELEGRAM_CHAT_ID unset — will refuse captures and report chat IDs")
	}

	a := &app{mcp: newMcpClient(mcpBin, notesDir), notesDir: notesDir, allowed: allowed}
	if err := a.mcp.Start(); err != nil {
		log.Fatalf("cannot start MCP server: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	b, err := bot.New(token, bot.WithDefaultHandler(a.handle))
	if err != nil {
		log.Fatalf("telegram: %v", err)
	}
	log.Printf("capturing to %s via %s", notesDir, mcpBin)
	b.Start(ctx)
}

func (a *app) handle(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.CallbackQuery != nil {
		a.handleCallback(ctx, b, update.CallbackQuery)
		return
	}
	msg := update.Message
	if msg == nil {
		return
	}
	chatID := msg.Chat.ID

	if !a.allowed[chatID] {
		if len(a.allowed) == 0 {
			reply(ctx, b, msg, fmt.Sprintf(
				"Dross is not configured yet. Set DROSS_TELEGRAM_CHAT_ID=%d and restart the bot.", chatID))
		} else {
			log.Printf("ignoring message from unauthorized chat %d", chatID)
		}
		return
	}

	switch {
	case strings.HasPrefix(msg.Text, "/"):
		reply(ctx, b, msg,
			"Send me anything to capture it in your Dross inbox.\n"+
				"Text and forwards land in inbox.org; photos and files are archived with a literature note.\n"+
				"A message starting with a URL is archived too: I save a self-contained snapshot of the page (images included).")
	case len(msg.Photo) > 0:
		a.archivePhoto(ctx, b, msg)
	case msg.Document != nil:
		a.archiveFile(ctx, b, msg)
	case strings.TrimSpace(msg.Text) != "":
		if pageURL, rest, ok := splitURLMessage(msg.Text); ok {
			a.archiveURL(ctx, b, msg, pageURL, rest)
		} else {
			a.captureText(ctx, b, msg)
		}
	default:
		reply(ctx, b, msg, "Nothing capturable here — I take text, photos, and files.")
	}
}

func (a *app) captureText(ctx context.Context, b *bot.Bot, msg *models.Message) {
	a.captureTextWith(ctx, b, msg, "Captured to inbox.")
}

func (a *app) captureTextWith(ctx context.Context, b *bot.Bot, msg *models.Message, confirm string) {
	args := map[string]any{
		"content": msg.Text,
		"source":  source(msg),
	}
	res, err := a.mcp.CallTool("capture", args)
	if err != nil {
		replyErr(ctx, b, msg, err)
		return
	}
	text := confirm
	if related := a.relatedNotes(res); related != "" {
		text += "\n\nConnects to:\n" + related
	}
	reply(ctx, b, msg, text)
}

// Nudge scores below this are noise; similar-notes returns cosine
// similarity in [0,1].
const nudgeThreshold = 0.5

// relatedNotes turns a fresh capture into a "connects to" nudge via
// similar-notes. Best-effort: any failure (semantic search disabled, Voyage
// down) just drops the nudge, never the capture confirmation.
func (a *app) relatedNotes(captureResult string) string {
	var cap struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(captureResult), &cap); err != nil || cap.ID == "" {
		return ""
	}
	out, err := a.mcp.CallTool("similar-notes", map[string]any{"id": cap.ID, "limit": 3})
	if err != nil {
		log.Printf("similar-notes nudge skipped: %v", err)
		return ""
	}
	var hits []struct {
		Title  string  `json:"title"`
		Score  float64 `json:"score"`
		Linked bool    `json:"linked"`
	}
	if err := json.Unmarshal([]byte(out), &hits); err != nil {
		return ""
	}
	var lines []string
	for _, h := range hits {
		if h.Score >= nudgeThreshold && !h.Linked {
			lines = append(lines, fmt.Sprintf("• %s (%.2f)", h.Title, h.Score))
		}
	}
	return strings.Join(lines, "\n")
}

func (a *app) archivePhoto(ctx context.Context, b *bot.Bot, msg *models.Message) {
	best := msg.Photo[0]
	for _, p := range msg.Photo[1:] {
		if p.Width*p.Height > best.Width*best.Height {
			best = p
		}
	}
	when := time.Unix(int64(msg.Date), 0)
	name := "telegram-photo-" + when.Format("2006-01-02-150405") + ".jpg"
	a.archive(ctx, b, msg, best.FileID, name,
		"Telegram photo "+when.Format("2006-01-02 15:04"))
}

func (a *app) archiveFile(ctx context.Context, b *bot.Bot, msg *models.Message) {
	doc := msg.Document
	when := time.Unix(int64(msg.Date), 0)
	name := doc.FileName
	if name == "" {
		name = "telegram-file-" + when.Format("2006-01-02-150405")
	}
	title := doc.FileName
	if title == "" {
		title = "Telegram file " + when.Format("2006-01-02 15:04")
	}
	a.archive(ctx, b, msg, doc.FileID, name, title)
}

// archive downloads a Telegram file into a temp dir (archive-document
// copies it into the attach dir, so the temp copy is discarded after) and
// creates the literature note. The caption's first line overrides the
// default title; remaining lines become the note body.
func (a *app) archive(ctx context.Context, b *bot.Bot, msg *models.Message, fileID, name, defaultTitle string) {
	title := defaultTitle
	body := ""
	if cap := strings.TrimSpace(msg.Caption); cap != "" {
		title, body, _ = strings.Cut(cap, "\n")
		title = strings.TrimSpace(title)
		body = strings.TrimSpace(body)
	}

	dir, err := os.MkdirTemp("", "dross-capture-")
	if err != nil {
		replyErr(ctx, b, msg, err)
		return
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, name)
	if err := a.download(ctx, b, fileID, path); err != nil {
		replyErr(ctx, b, msg, err)
		return
	}

	args := map[string]any{
		"path":   path,
		"title":  title,
		"source": source(msg),
	}
	if body != "" {
		args["content"] = body
	}
	if _, err := a.mcp.CallTool("archive-document", args); err != nil {
		replyErr(ctx, b, msg, err)
		return
	}
	reply(ctx, b, msg, "Archived: "+title)
}

// archiveURL snapshots a captured URL (self-contained HTML, images inlined)
// and archives it as a literature note tagged inbox so triage still sees it.
// The message text after the URL becomes the note body; readability-extracted
// text is indexed via archive-document's text parameter. A failed fetch falls
// back to a plain inbox capture — the URL is never lost. Arxiv links of any
// form (/abs/, /pdf/, /html/) are normalized: the abs page is snapshotted for
// title/abstract, the PDF is downloaded alongside (best-effort) and its
// pdftotext output replaces the abstract as the indexed text. All fetching
// finishes before CallTool, so the MCP mutex is never held during network I/O.
func (a *app) archiveURL(ctx context.Context, b *bot.Bot, msg *models.Message, pageURL, body string) {
	_, _ = b.SendChatAction(ctx, &bot.SendChatActionParams{
		ChatID: msg.Chat.ID,
		Action: models.ChatActionUploadDocument,
	})

	fetchURL := pageURL
	arxiv, isArxiv := arxivID(pageURL)
	if isArxiv {
		fetchURL = "https://arxiv.org/abs/" + arxiv
	}

	page, err := fetchPage(ctx, fetchURL)
	if err != nil {
		log.Printf("archiving %s failed, capturing instead: %v", fetchURL, err)
		a.captureTextWith(ctx, b, msg,
			"Couldn't fetch the page — captured the link to inbox instead.")
		return
	}

	title := page.title
	if title == "" {
		if u, uerr := url.Parse(pageURL); uerr == nil {
			title = strings.TrimSpace(u.Host + u.Path)
		} else {
			title = pageURL
		}
	}

	dir, err := os.MkdirTemp("", "dross-capture-")
	if err != nil {
		replyErr(ctx, b, msg, err)
		return
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, snapshotName(page.title, fetchURL, page.contentType))
	if err := os.WriteFile(path, page.data, 0o644); err != nil {
		replyErr(ctx, b, msg, err)
		return
	}

	src := pageURL
	if from := source(msg); from != "telegram" {
		src += " (via " + from + ")"
	}
	args := map[string]any{
		"path":   path,
		"title":  title,
		"source": src,
		"tags":   []string{"inbox"},
	}
	if body != "" {
		args["content"] = body
	}
	if page.text != "" {
		args["text"] = page.text
	}

	pdfNote := ""
	if isArxiv {
		pdfPath, pdfText, pdfErr := a.arxivPDF(ctx, dir, arxiv)
		if pdfErr != nil {
			log.Printf("arxiv PDF for %s skipped: %v", arxiv, pdfErr)
			pdfNote = "\n(couldn't download the PDF — only the abstract page was saved)"
		} else {
			args["extra_paths"] = []string{pdfPath}
			if pdfText != "" {
				args["text"] = pdfText
			}
			pdfNote = "\n(PDF attached)"
		}
	}

	res, err := a.mcp.CallTool("archive-document", args)
	if err != nil {
		replyErr(ctx, b, msg, err)
		return
	}

	text := "Archived: " + title + "\n" + pageURL + pdfNote
	if strings.HasPrefix(page.contentType, "text/html") && page.text == "" && args["text"] == nil {
		text += "\n(no readable text extracted — the page may need JavaScript; only the snapshot was saved)"
	}
	if related := a.relatedNotes(res); related != "" {
		text += "\n\nConnects to:\n" + related
	}
	reply(ctx, b, msg, text)
}

// arxivPDF downloads the paper's PDF into dir and extracts its full text
// with pdftotext. The download failing is an error (the caller falls back
// to snapshot-only); extraction failing is not — a missing pdftotext just
// means the abstract stays the indexed text.
func (a *app) arxivPDF(ctx context.Context, dir, arxiv string) (path, text string, err error) {
	data, err := fetchFile(ctx, "https://arxiv.org/pdf/"+arxiv)
	if err != nil {
		return "", "", err
	}
	name := strings.ReplaceAll(arxiv, "/", "-") + ".pdf"
	path = filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return "", "", err
	}
	text, terr := pdfText(ctx, path)
	if terr != nil {
		log.Printf("pdftotext on %s skipped: %v", name, terr)
	}
	return path, text, nil
}

func (a *app) download(ctx context.Context, b *bot.Bot, fileID, dest string) error {
	file, err := b.GetFile(ctx, &bot.GetFileParams{FileID: fileID})
	if err != nil {
		return fmt.Errorf("telegram getFile: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, b.FileDownloadLink(file), nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("downloading from telegram: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("downloading from telegram: %s", resp.Status)
	}
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, resp.Body)
	return err
}

// source describes where a capture came from: plain sends are "telegram";
// forwards credit the original sender so inbox processing can cite it.
func source(msg *models.Message) string {
	o := msg.ForwardOrigin
	if o == nil {
		return "telegram"
	}
	switch o.Type {
	case models.MessageOriginTypeUser:
		u := o.MessageOriginUser.SenderUser
		name := strings.TrimSpace(u.FirstName + " " + u.LastName)
		if u.Username != "" {
			name += " (@" + u.Username + ")"
		}
		return "telegram forward from " + name
	case models.MessageOriginTypeHiddenUser:
		return "telegram forward from " + o.MessageOriginHiddenUser.SenderUserName
	case models.MessageOriginTypeChat:
		return "telegram forward from " + o.MessageOriginChat.SenderChat.Title
	case models.MessageOriginTypeChannel:
		return "telegram forward from " + o.MessageOriginChannel.Chat.Title
	}
	return "telegram forward"
}

func reply(ctx context.Context, b *bot.Bot, msg *models.Message, text string) {
	_, err := b.SendMessage(ctx, &bot.SendMessageParams{
		ChatID:          msg.Chat.ID,
		Text:            text,
		ReplyParameters: &models.ReplyParameters{MessageID: msg.ID},
	})
	if err != nil {
		log.Printf("sendMessage: %v", err)
	}
}

func replyErr(ctx context.Context, b *bot.Bot, msg *models.Message, err error) {
	log.Printf("capture failed: %v", err)
	reply(ctx, b, msg, "Capture failed: "+err.Error())
}
