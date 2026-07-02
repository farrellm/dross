package main

// Minimal MCP client: spawns dross-mcp and speaks newline-delimited
// JSON-RPC 2.0 over its stdio. All note writes go through the server's
// tools so the write policy (atomic writes, IDs, indexing) lives in one
// place. Calls are serialized; if the subprocess dies, the next call
// restarts it once and retries.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
)

type mcpClient struct {
	mu       sync.Mutex
	bin      string
	notesDir string
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	stdout   *bufio.Reader
	nextID   int64
}

func newMcpClient(bin, notesDir string) *mcpClient {
	return &mcpClient{bin: bin, notesDir: notesDir}
}

type rpcRequest struct {
	Jsonrpc string `json:"jsonrpc"`
	ID      *int64 `json:"id,omitempty"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

type rpcResponse struct {
	ID     *int64          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type toolResult struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	IsError bool `json:"isError"`
}

// start launches the subprocess and performs the initialize handshake.
// Caller holds c.mu.
func (c *mcpClient) start() error {
	cmd := exec.Command(c.bin, c.notesDir)
	cmd.Stderr = os.Stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting %s: %w", c.bin, err)
	}
	c.cmd = cmd
	c.stdin = stdin
	c.stdout = bufio.NewReader(stdout)

	initParams := map[string]any{
		"protocolVersion": "2025-06-18",
		"capabilities":    map[string]any{},
		"clientInfo":      map[string]any{"name": "dross-bot", "version": "0.1.0"},
	}
	if _, err := c.roundTrip("initialize", initParams); err != nil {
		c.stop()
		return fmt.Errorf("mcp initialize: %w", err)
	}
	return c.send(rpcRequest{Jsonrpc: "2.0", Method: "notifications/initialized"})
}

// stop kills the subprocess and forgets it. Caller holds c.mu.
func (c *mcpClient) stop() {
	if c.cmd != nil {
		c.stdin.Close()
		c.cmd.Process.Kill()
		c.cmd.Wait()
	}
	c.cmd = nil
	c.stdin = nil
	c.stdout = nil
}

func (c *mcpClient) send(req rpcRequest) error {
	line, err := json.Marshal(req)
	if err != nil {
		return err
	}
	_, err = c.stdin.Write(append(line, '\n'))
	return err
}

// roundTrip sends one request and reads lines until the matching
// response arrives. Caller holds c.mu.
func (c *mcpClient) roundTrip(method string, params any) (json.RawMessage, error) {
	c.nextID++
	id := c.nextID
	if err := c.send(rpcRequest{Jsonrpc: "2.0", ID: &id, Method: method, Params: params}); err != nil {
		return nil, err
	}
	for {
		line, err := c.stdout.ReadBytes('\n')
		if err != nil {
			return nil, fmt.Errorf("reading from %s: %w", c.bin, err)
		}
		var resp rpcResponse
		if err := json.Unmarshal(line, &resp); err != nil {
			return nil, fmt.Errorf("bad JSON-RPC line from %s: %w", c.bin, err)
		}
		if resp.ID == nil || *resp.ID != id {
			continue // not ours (server currently sends none, but be safe)
		}
		if resp.Error != nil {
			return nil, fmt.Errorf("rpc error %d: %s", resp.Error.Code, resp.Error.Message)
		}
		return resp.Result, nil
	}
}

// CallTool invokes an MCP tool and returns the JSON text payload of the
// result. A tool-level failure (isError) or a dead subprocess comes back
// as an error; the subprocess is restarted once before giving up.
func (c *mcpClient) CallTool(name string, args map[string]any) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	restarted := false
	for {
		if c.cmd == nil {
			if err := c.start(); err != nil {
				return "", err
			}
		}
		params := map[string]any{"name": name, "arguments": args}
		raw, err := c.roundTrip("tools/call", params)
		if err != nil {
			c.stop()
			if restarted {
				return "", err
			}
			restarted = true
			continue
		}
		var res toolResult
		if err := json.Unmarshal(raw, &res); err != nil {
			return "", fmt.Errorf("bad tool result: %w", err)
		}
		text := ""
		if len(res.Content) > 0 {
			text = res.Content[0].Text
		}
		if res.IsError {
			return "", fmt.Errorf("%s: %s", name, text)
		}
		return text, nil
	}
}

// Start eagerly launches the subprocess so misconfiguration (missing
// binary, database down) surfaces at boot instead of on first capture.
func (c *mcpClient) Start() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cmd != nil {
		return nil
	}
	return c.start()
}
