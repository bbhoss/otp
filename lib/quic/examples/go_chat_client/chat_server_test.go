// chat_server_test.go - Embedded Go QUIC chat server for testing
//
// This implements the same protocol as quic_chat_server.erl so we can
// verify the Go client works end-to-end without needing the Erlang runtime.
//
// Run:  go test -v -run TestChatE2E -count=1

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"sync"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
)

// ---------- tiny in-process chat server ----------

type chatRoom struct {
	mu      sync.Mutex
	members map[string]quic.Stream // nick -> stream
}

var (
	roomsMu sync.Mutex
	rooms   = map[string]*chatRoom{}
)

func getRoom(name string) *chatRoom {
	roomsMu.Lock()
	defer roomsMu.Unlock()
	r, ok := rooms[name]
	if !ok {
		r = &chatRoom{members: map[string]quic.Stream{}}
		rooms[name] = r
	}
	return r
}

func (r *chatRoom) join(nick string, stream quic.Stream) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	// Broadcast "enter" to existing members
	enter, _ := json.Marshal(map[string]string{"ev": "enter", "nick": nick})
	for _, s := range r.members {
		sendFrame(s, enter)
	}
	existing := make([]string, 0, len(r.members))
	for n := range r.members {
		existing = append(existing, n)
	}
	r.members[nick] = stream
	return existing
}

func (r *chatRoom) leave(nick string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.members, nick)
	left, _ := json.Marshal(map[string]string{"ev": "left", "nick": nick})
	for _, s := range r.members {
		sendFrame(s, left)
	}
}

func (r *chatRoom) broadcast(fromNick, text string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	msg, _ := json.Marshal(map[string]string{
		"ev": "msg", "nick": fromNick, "text": text,
	})
	for nick, s := range r.members {
		if nick != fromNick {
			sendFrame(s, msg)
		}
	}
}

func sendFrame(stream quic.Stream, payload []byte) {
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(payload)))
	stream.Write(hdr)
	stream.Write(payload)
}

func serverReadFrame(stream quic.Stream) (map[string]any, error) {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(stream, hdr); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(hdr)
	payload := make([]byte, length)
	if _, err := io.ReadFull(stream, payload); err != nil {
		return nil, err
	}
	var m map[string]any
	json.Unmarshal(payload, &m)
	return m, nil
}

func handleChatStream(stream quic.Stream) {
	var currentRoom *chatRoom
	var nick string

	defer func() {
		if currentRoom != nil && nick != "" {
			currentRoom.leave(nick)
		}
		stream.Close()
	}()

	for {
		msg, err := serverReadFrame(stream)
		if err != nil {
			return
		}

		cmd, _ := msg["cmd"].(string)
		switch cmd {
		case "join":
			if currentRoom != nil && nick != "" {
				currentRoom.leave(nick)
			}
			roomName, _ := msg["room"].(string)
			nick, _ = msg["nick"].(string)
			currentRoom = getRoom(roomName)
			existing := currentRoom.join(nick, stream)
			resp, _ := json.Marshal(map[string]any{
				"ev":      "joined",
				"room":    roomName,
				"members": existing,
			})
			sendFrame(stream, resp)

		case "msg":
			text, _ := msg["text"].(string)
			if currentRoom != nil {
				currentRoom.broadcast(nick, text)
			}

		case "leave":
			if currentRoom != nil && nick != "" {
				currentRoom.leave(nick)
				currentRoom = nil
			}
			resp, _ := json.Marshal(map[string]string{"ev": "left_ok"})
			sendFrame(stream, resp)
		}
	}
}

func handleChatConn(conn quic.Connection) {
	for {
		stream, err := conn.AcceptStream(context.Background())
		if err != nil {
			return
		}
		go handleChatStream(stream)
	}
}

// ---------- Self-signed cert helper ----------

func selfSignedTLS() *tls.Config {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		DNSNames:     []string{"localhost"},
	}
	certDER, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	cert := tls.Certificate{
		Certificate: [][]byte{certDER},
		PrivateKey:  key,
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"chat"},
	}
}

// ---------- End-to-end test ----------

func TestChatE2E(t *testing.T) {
	// Reset global rooms
	roomsMu.Lock()
	rooms = map[string]*chatRoom{}
	roomsMu.Unlock()

	// Start server
	tlsConf := selfSignedTLS()
	listener, err := quic.ListenAddr("127.0.0.1:0", tlsConf, &quic.Config{
		MaxIdleTimeout:  10 * time.Second,
		EnableDatagrams: true,
	})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	addr := listener.Addr().String()
	t.Logf("Server listening on %s", addr)

	go func() {
		for {
			conn, err := listener.Accept(context.Background())
			if err != nil {
				return
			}
			go handleChatConn(conn)
		}
	}()

	clientTLS := &tls.Config{
		NextProtos:         []string{"chat"},
		InsecureSkipVerify: true,
	}
	clientConf := &quic.Config{
		MaxIdleTimeout:  10 * time.Second,
		EnableDatagrams: true,
	}

	ctx := context.Background()

	// -- Alice connects and joins "lobby" --
	aliceConn, err := quic.DialAddr(ctx, addr, clientTLS, clientConf)
	if err != nil {
		t.Fatalf("alice connect: %v", err)
	}
	defer aliceConn.CloseWithError(0, "done")
	aliceStream, _ := aliceConn.OpenStreamSync(ctx)

	writeFrame(aliceStream, joinCmd{Cmd: "join", Room: "lobby", Nick: "alice"})
	resp, _ := readFrame(aliceStream)
	t.Logf("Alice joined: %v", resp)

	if ev, _ := resp["ev"].(string); ev != "joined" {
		t.Fatalf("expected joined, got %v", resp)
	}
	members, _ := resp["members"].([]any)
	if len(members) != 0 {
		t.Fatalf("expected empty members, got %v", members)
	}

	// -- Bob connects and joins "lobby" --
	bobConn, err := quic.DialAddr(ctx, addr, clientTLS, clientConf)
	if err != nil {
		t.Fatalf("bob connect: %v", err)
	}
	defer bobConn.CloseWithError(0, "done")
	bobStream, _ := bobConn.OpenStreamSync(ctx)

	writeFrame(bobStream, joinCmd{Cmd: "join", Room: "lobby", Nick: "bob"})
	resp, _ = readFrame(bobStream)
	t.Logf("Bob joined: %v", resp)

	if ev, _ := resp["ev"].(string); ev != "joined" {
		t.Fatalf("expected joined, got %v", resp)
	}
	members, _ = resp["members"].([]any)
	if len(members) != 1 {
		t.Fatalf("expected 1 member (alice), got %v", members)
	}

	// Alice should have received "enter" for Bob
	enterMsg, _ := readFrame(aliceStream)
	t.Logf("Alice sees enter: %v", enterMsg)
	if n, _ := enterMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected bob enter, got %v", enterMsg)
	}

	// -- Bob sends a message --
	writeFrame(bobStream, msgCmd{Cmd: "msg", Text: "hello everyone!"})

	// Alice should receive it
	chatMsg, _ := readFrame(aliceStream)
	t.Logf("Alice receives: %v", chatMsg)
	if text, _ := chatMsg["text"].(string); text != "hello everyone!" {
		t.Fatalf("expected 'hello everyone!', got %v", chatMsg)
	}
	if n, _ := chatMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected nick=bob, got %v", chatMsg)
	}

	// -- Alice replies --
	writeFrame(aliceStream, msgCmd{Cmd: "msg", Text: "hey bob!"})

	bobMsg, _ := readFrame(bobStream)
	t.Logf("Bob receives: %v", bobMsg)
	if text, _ := bobMsg["text"].(string); text != "hey bob!" {
		t.Fatalf("expected 'hey bob!', got %v", bobMsg)
	}

	// -- Charlie joins, everyone should see --
	charlieConn, err := quic.DialAddr(ctx, addr, clientTLS, clientConf)
	if err != nil {
		t.Fatalf("charlie connect: %v", err)
	}
	defer charlieConn.CloseWithError(0, "done")
	charlieStream, _ := charlieConn.OpenStreamSync(ctx)

	writeFrame(charlieStream, joinCmd{Cmd: "join", Room: "lobby", Nick: "charlie"})
	resp, _ = readFrame(charlieStream)
	t.Logf("Charlie joined: %v", resp)
	members, _ = resp["members"].([]any)
	if len(members) != 2 {
		t.Fatalf("expected 2 members, got %d: %v", len(members), members)
	}

	// Alice and Bob see charlie enter
	aliceEnter, _ := readFrame(aliceStream)
	t.Logf("Alice sees charlie enter: %v", aliceEnter)
	bobEnter, _ := readFrame(bobStream)
	t.Logf("Bob sees charlie enter: %v", bobEnter)

	// -- Bob leaves --
	writeFrame(bobStream, leaveCmd{Cmd: "leave"})
	leaveResp, _ := readFrame(bobStream)
	t.Logf("Bob leave response: %v", leaveResp)

	// Alice and Charlie should see bob left
	aliceLeft, _ := readFrame(aliceStream)
	t.Logf("Alice sees bob left: %v", aliceLeft)
	if n, _ := aliceLeft["nick"].(string); n != "bob" {
		t.Fatalf("expected bob left, got %v", aliceLeft)
	}
	charlieLeft, _ := readFrame(charlieStream)
	t.Logf("Charlie sees bob left: %v", charlieLeft)

	// -- Charlie switches to a different room --
	writeFrame(charlieStream, joinCmd{Cmd: "join", Room: "vip", Nick: "charlie"})
	resp, _ = readFrame(charlieStream)
	t.Logf("Charlie joined vip: %v", resp)

	// Alice should see charlie left
	aliceCharlieLeft, _ := readFrame(aliceStream)
	t.Logf("Alice sees charlie left: %v", aliceCharlieLeft)
	if n, _ := aliceCharlieLeft["nick"].(string); n != "charlie" {
		t.Fatalf("expected charlie left, got %v", aliceCharlieLeft)
	}

	fmt.Println("=== All chat protocol tests PASSED ===")
}
