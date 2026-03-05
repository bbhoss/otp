// QUIC Multi-Room Chat Client with TUI
//
// Demonstrates QUIC stream multiplexing: each chat room runs on its own
// independent QUIC bidirectional stream. Messages in different rooms never
// block each other — true multiplexing with zero head-of-line blocking.
//
// Usage:
//   go run main.go --addr localhost:4433 --nick alice
//
// Keys:
//   Ctrl+J  — Join a new room (opens a new QUIC stream)
//   Ctrl+W  — Leave current room (closes that stream)
//   Tab     — Switch focus between room list and message input
//   Enter   — Send message to current room
//   Ctrl+C  — Quit

package main

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gdamore/tcell/v2"
	"github.com/quic-go/quic-go"
	"github.com/rivo/tview"
)

// --- Wire protocol helpers (4-byte big-endian length + JSON) -----------

func writeFrame(stream quic.Stream, msg any) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(data)))
	if _, err := stream.Write(hdr); err != nil {
		return fmt.Errorf("write header: %w", err)
	}
	if _, err := stream.Write(data); err != nil {
		return fmt.Errorf("write payload: %w", err)
	}
	return nil
}

func readFrame(stream quic.Stream) (map[string]any, error) {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(stream, hdr); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(hdr)
	if length > 1<<20 {
		return nil, fmt.Errorf("frame too large: %d bytes", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(stream, payload); err != nil {
		return nil, err
	}
	var msg map[string]any
	if err := json.Unmarshal(payload, &msg); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}
	return msg, nil
}

// --- Commands ----------------------------------------------------------

type joinCmd struct {
	Cmd  string `json:"cmd"`
	Room string `json:"room"`
	Nick string `json:"nick"`
}

type msgCmd struct {
	Cmd  string `json:"cmd"`
	Text string `json:"text"`
}

type leaveCmd struct {
	Cmd string `json:"cmd"`
}

// --- Room state --------------------------------------------------------

type RoomState struct {
	name     string
	stream   quic.Stream
	textView *tview.TextView
	streamID int64
}

// --- Chat application --------------------------------------------------

type ChatApp struct {
	app  *tview.Application
	conn quic.Connection
	nick string
	addr string

	mu         sync.Mutex
	rooms      map[string]*RoomState // room name -> state
	roomOrder  []string              // ordered room names
	activeRoom string

	// widgets
	roomList   *tview.List
	chatPages  *tview.Pages
	inputField *tview.InputField
	statusBar  *tview.TextView
	helpText   *tview.TextView
	mainPages  *tview.Pages // for join dialog overlay
	mainLayout tview.Primitive
}

func newChatApp(conn quic.Connection, nick, addr string) *ChatApp {
	c := &ChatApp{
		app:   tview.NewApplication(),
		conn:  conn,
		nick:  nick,
		addr:  addr,
		rooms: make(map[string]*RoomState),
	}
	c.buildUI()
	return c
}

func (c *ChatApp) buildUI() {
	// Room list (left sidebar)
	c.roomList = tview.NewList()
	c.roomList.SetBorder(true)
	c.roomList.SetTitle(" Rooms ")
	c.roomList.SetHighlightFullLine(true)
	c.roomList.ShowSecondaryText(true)
	c.roomList.SetChangedFunc(func(index int, mainText, secondaryText string, shortcut rune) {
		// Extract room name (strip the # prefix)
		name := strings.TrimPrefix(mainText, "#")
		c.switchToRoom(name)
	})

	// Help text
	c.helpText = tview.NewTextView()
	c.helpText.SetDynamicColors(true)
	c.helpText.SetText("[yellow]Ctrl+J[white] Join room\n[yellow]Ctrl+W[white] Leave room\n[yellow]Tab[white]    Switch focus\n[yellow]Ctrl+C[white] Quit")
	c.helpText.SetBorder(true)

	// Sidebar
	sidebar := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(c.roomList, 0, 1, false).
		AddItem(c.helpText, 6, 0, false)

	// Chat pages (one page per room)
	c.chatPages = tview.NewPages()

	// Empty state
	emptyView := tview.NewTextView()
	emptyView.SetDynamicColors(true)
	emptyView.SetTextAlign(tview.AlignCenter)
	emptyView.SetText("\n\n\n[gray]Press [yellow]Ctrl+J[gray] to join a room")
	c.chatPages.AddPage("empty", emptyView, true, true)

	// Input field
	c.inputField = tview.NewInputField()
	c.inputField.SetLabel("> ")
	c.inputField.SetFieldBackgroundColor(tcell.ColorDefault)
	c.inputField.SetBorder(true)
	c.inputField.SetDoneFunc(func(key tcell.Key) {
		if key == tcell.KeyEnter {
			c.sendMessage()
		}
	})

	// Status bar
	c.statusBar = tview.NewTextView()
	c.statusBar.SetDynamicColors(true)
	c.updateStatus()

	// Right side
	rightSide := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(c.chatPages, 0, 1, false).
		AddItem(c.inputField, 3, 0, true).
		AddItem(c.statusBar, 1, 0, false)

	// Main layout
	mainFlex := tview.NewFlex().
		AddItem(sidebar, 24, 0, false).
		AddItem(rightSide, 0, 1, true)

	c.mainLayout = mainFlex

	// Pages for overlaying dialogs
	c.mainPages = tview.NewPages()
	c.mainPages.AddPage("main", mainFlex, true, true)

	// Global key bindings
	c.app.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
		switch event.Key() {
		case tcell.KeyCtrlJ:
			c.showJoinDialog()
			return nil
		case tcell.KeyCtrlW:
			c.leaveCurrentRoom()
			return nil
		case tcell.KeyTab:
			c.toggleFocus()
			return nil
		}
		return event
	})

	c.app.SetRoot(c.mainPages, true)
	c.app.SetFocus(c.inputField)
}

func (c *ChatApp) updateStatus() {
	c.mu.Lock()
	n := len(c.rooms)
	c.mu.Unlock()

	streamWord := "streams"
	if n == 1 {
		streamWord = "stream"
	}
	c.statusBar.SetText(fmt.Sprintf(
		" [green]●[white] %s | [cyan]%s[white] | %d %s",
		c.addr, c.nick, n, streamWord,
	))
}

func (c *ChatApp) toggleFocus() {
	if c.app.GetFocus() == c.inputField {
		c.app.SetFocus(c.roomList)
	} else {
		c.app.SetFocus(c.inputField)
	}
}

// --- Join a room -------------------------------------------------------

func (c *ChatApp) showJoinDialog() {
	input := tview.NewInputField()
	input.SetLabel("Room: #")
	input.SetFieldWidth(30)

	form := tview.NewForm().
		AddFormItem(input).
		AddButton("Join", func() {
			name := strings.TrimSpace(input.GetText())
			if name != "" {
				c.mainPages.SwitchToPage("main")
				c.mainPages.RemovePage("join-dialog")
				c.app.SetFocus(c.inputField)
				go c.joinRoom(name)
			}
		}).
		AddButton("Cancel", func() {
			c.mainPages.SwitchToPage("main")
			c.mainPages.RemovePage("join-dialog")
			c.app.SetFocus(c.inputField)
		})
	form.SetBorder(true)
	form.SetTitle(" Join Room ")
	form.SetTitleAlign(tview.AlignCenter)

	// Center the dialog
	modal := tview.NewFlex().
		AddItem(nil, 0, 1, false).
		AddItem(tview.NewFlex().SetDirection(tview.FlexRow).
			AddItem(nil, 0, 1, false).
			AddItem(form, 9, 0, true).
			AddItem(nil, 0, 1, false), 50, 0, true).
		AddItem(nil, 0, 1, false)

	c.mainPages.AddAndSwitchToPage("join-dialog", modal, true)
	c.app.SetFocus(input)
}

func (c *ChatApp) joinRoom(name string) {
	c.mu.Lock()
	if _, exists := c.rooms[name]; exists {
		c.mu.Unlock()
		// Already in this room, just switch to it
		c.app.QueueUpdateDraw(func() {
			c.switchToRoom(name)
		})
		return
	}
	c.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Open a NEW QUIC stream for this room
	stream, err := c.conn.OpenStreamSync(ctx)
	if err != nil {
		c.app.QueueUpdateDraw(func() {
			c.appendSystem("", fmt.Sprintf("Failed to open stream: %v", err))
		})
		return
	}

	// Send join command on this stream
	if err := writeFrame(stream, joinCmd{Cmd: "join", Room: name, Nick: c.nick}); err != nil {
		stream.Close()
		c.app.QueueUpdateDraw(func() {
			c.appendSystem("", fmt.Sprintf("Failed to join %s: %v", name, err))
		})
		return
	}

	// Wait for joined response
	resp, err := readFrame(stream)
	if err != nil {
		stream.Close()
		c.app.QueueUpdateDraw(func() {
			c.appendSystem("", fmt.Sprintf("Failed to join %s: %v", name, err))
		})
		return
	}

	ev, _ := resp["ev"].(string)
	if ev != "joined" {
		errText, _ := resp["text"].(string)
		stream.Close()
		c.app.QueueUpdateDraw(func() {
			c.appendSystem("", fmt.Sprintf("Join %s failed: %s", name, errText))
		})
		return
	}

	// Create room state
	tv := tview.NewTextView()
	tv.SetDynamicColors(true)
	tv.SetScrollable(true)
	tv.SetWordWrap(true)
	tv.SetBorder(true)
	tv.SetTitle(fmt.Sprintf(" #%s (stream %d) ", name, stream.StreamID()))

	members, _ := resp["members"].([]any)
	memberNames := make([]string, len(members))
	for i, m := range members {
		memberNames[i], _ = m.(string)
	}

	room := &RoomState{
		name:     name,
		stream:   stream,
		textView: tv,
		streamID: int64(stream.StreamID()),
	}

	c.mu.Lock()
	c.rooms[name] = room
	c.roomOrder = append(c.roomOrder, name)
	c.mu.Unlock()

	// Update UI
	c.app.QueueUpdateDraw(func() {
		c.chatPages.AddPage(name, tv, true, false)
		c.roomList.AddItem("#"+name, fmt.Sprintf("  stream %d", stream.StreamID()), 0, nil)
		c.switchToRoom(name)
		c.updateStatus()

		if len(memberNames) == 0 {
			fmt.Fprintf(tv, "[gray]You're the first one here.[white]\n")
		} else {
			fmt.Fprintf(tv, "[gray]Members: %s[white]\n", strings.Join(memberNames, ", "))
		}
		fmt.Fprintf(tv, "[green]* Joined #%s[white]\n", name)
	})

	// Start read loop for this room's stream
	go c.readLoop(name, stream)
}

// --- Read loop (one goroutine per room/stream) -------------------------

func (c *ChatApp) readLoop(roomName string, stream quic.Stream) {
	for {
		msg, err := readFrame(stream)
		if err != nil {
			c.app.QueueUpdateDraw(func() {
				c.removeRoom(roomName)
			})
			return
		}
		c.app.QueueUpdateDraw(func() {
			c.handleEvent(roomName, msg)
		})
	}
}

func (c *ChatApp) handleEvent(roomName string, msg map[string]any) {
	c.mu.Lock()
	room, ok := c.rooms[roomName]
	c.mu.Unlock()
	if !ok {
		return
	}

	ev, _ := msg["ev"].(string)
	switch ev {
	case "msg":
		nick, _ := msg["nick"].(string)
		text, _ := msg["text"].(string)
		fmt.Fprintf(room.textView, "[cyan]<%s>[white] %s\n", nick, tview.Escape(text))
	case "enter":
		nick, _ := msg["nick"].(string)
		fmt.Fprintf(room.textView, "[green]* %s joined the room[white]\n", nick)
	case "left":
		nick, _ := msg["nick"].(string)
		fmt.Fprintf(room.textView, "[yellow]* %s left the room[white]\n", nick)
	case "error":
		text, _ := msg["text"].(string)
		fmt.Fprintf(room.textView, "[red][error] %s[white]\n", text)
	default:
		fmt.Fprintf(room.textView, "[gray]%v[white]\n", msg)
	}
	room.textView.ScrollToEnd()
}

// --- Send message ------------------------------------------------------

func (c *ChatApp) sendMessage() {
	text := strings.TrimSpace(c.inputField.GetText())
	if text == "" {
		return
	}
	c.inputField.SetText("")

	// Handle /join command inline
	if strings.HasPrefix(text, "/join ") {
		parts := strings.SplitN(text, " ", 2)
		if len(parts) == 2 && strings.TrimSpace(parts[1]) != "" {
			go c.joinRoom(strings.TrimSpace(parts[1]))
			return
		}
	}

	c.mu.Lock()
	room, ok := c.rooms[c.activeRoom]
	c.mu.Unlock()
	if !ok {
		return
	}

	// Show own message locally
	fmt.Fprintf(room.textView, "[cyan::b]<%s>[white] %s\n", c.nick, tview.Escape(text))
	room.textView.ScrollToEnd()

	// Send on the room's stream
	go func() {
		if err := writeFrame(room.stream, msgCmd{Cmd: "msg", Text: text}); err != nil {
			c.app.QueueUpdateDraw(func() {
				c.appendSystem(room.name, fmt.Sprintf("Send failed: %v", err))
			})
		}
	}()
}

// --- Leave room --------------------------------------------------------

func (c *ChatApp) leaveCurrentRoom() {
	c.mu.Lock()
	name := c.activeRoom
	room, ok := c.rooms[name]
	c.mu.Unlock()
	if !ok {
		return
	}

	// Close the QUIC stream — the server treats this as leaving
	room.stream.Close()
	c.removeRoom(name)
}

func (c *ChatApp) removeRoom(name string) {
	c.mu.Lock()
	_, exists := c.rooms[name]
	if !exists {
		c.mu.Unlock()
		return
	}
	delete(c.rooms, name)
	newOrder := make([]string, 0, len(c.roomOrder))
	removedIdx := -1
	for i, n := range c.roomOrder {
		if n == name {
			removedIdx = i
		} else {
			newOrder = append(newOrder, n)
		}
	}
	c.roomOrder = newOrder
	c.mu.Unlock()

	c.chatPages.RemovePage(name)

	// Remove from room list
	if removedIdx >= 0 {
		c.roomList.RemoveItem(removedIdx)
	}

	c.mu.Lock()
	remaining := len(c.rooms)
	c.mu.Unlock()

	if remaining == 0 {
		c.activeRoom = ""
		c.chatPages.SwitchToPage("empty")
		c.inputField.SetTitle("")
	} else {
		// Switch to the next room
		c.mu.Lock()
		nextRoom := c.roomOrder[0]
		c.mu.Unlock()
		c.switchToRoom(nextRoom)
	}
	c.updateStatus()
}

// --- Switch to room ----------------------------------------------------

func (c *ChatApp) switchToRoom(name string) {
	c.mu.Lock()
	_, ok := c.rooms[name]
	c.mu.Unlock()
	if !ok {
		return
	}

	c.activeRoom = name
	c.chatPages.SwitchToPage(name)

	// Highlight in room list
	for i := 0; i < c.roomList.GetItemCount(); i++ {
		mainText, _ := c.roomList.GetItemText(i)
		if strings.TrimPrefix(mainText, "#") == name {
			c.roomList.SetCurrentItem(i)
			break
		}
	}
}

// --- System message helper ---------------------------------------------

func (c *ChatApp) appendSystem(roomName, text string) {
	if roomName == "" {
		// Show in all rooms or ignore
		return
	}
	c.mu.Lock()
	room, ok := c.rooms[roomName]
	c.mu.Unlock()
	if ok {
		fmt.Fprintf(room.textView, "[red]%s[white]\n", text)
	}
}

// --- Run ---------------------------------------------------------------

func (c *ChatApp) run() error {
	return c.app.Run()
}

// --- Main --------------------------------------------------------------

func main() {
	addr := flag.String("addr", "localhost:4433", "Server address")
	nick := flag.String("nick", "", "Your nickname (required)")
	room := flag.String("room", "lobby", "Initial room to join")
	insecure := flag.Bool("insecure", true, "Skip TLS verification")
	flag.Parse()

	if *nick == "" {
		fmt.Println("Error: --nick is required")
		flag.Usage()
		os.Exit(1)
	}

	tlsConf := &tls.Config{
		NextProtos:         []string{"chat"},
		InsecureSkipVerify: *insecure,
	}
	quicConf := &quic.Config{
		MaxIdleTimeout:  60 * time.Second,
		EnableDatagrams: true,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := quic.DialAddr(ctx, *addr, tlsConf, quicConf)
	if err != nil {
		log.Fatalf("Connect failed: %v", err)
	}
	defer conn.CloseWithError(0, "bye")

	chatApp := newChatApp(conn, *nick, *addr)

	// Join the initial room in background
	go chatApp.joinRoom(*room)

	if err := chatApp.run(); err != nil {
		log.Fatalf("TUI error: %v", err)
	}
}
