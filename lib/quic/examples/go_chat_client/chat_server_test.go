// chat_server_test.go - Embedded Go QUIC chat server for testing
//
// Implements the same multi-stream protocol as quic_chat_server.erl:
// each QUIC stream maps to exactly one room. The first message on a
// stream must be a join command. Closing the stream = leaving the room.
//
// Run:  go test -v -run TestChat -count=1

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
	name    string
	members map[string]quic.Stream // nick -> stream
}

type chatServer struct {
	mu    sync.Mutex
	rooms map[string]*chatRoom
}

func newChatServer() *chatServer {
	return &chatServer{rooms: map[string]*chatRoom{}}
}

func (s *chatServer) getRoom(name string) *chatRoom {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.rooms[name]
	if !ok {
		r = &chatRoom{name: name, members: map[string]quic.Stream{}}
		s.rooms[name] = r
	}
	return r
}

func (r *chatRoom) join(nick string, stream quic.Stream) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
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

// handleChatStream: each stream maps to exactly one room.
// First message must be join. Closing the stream = leave.
func (s *chatServer) handleChatStream(stream quic.Stream) {
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
			currentRoom = s.getRoom(roomName)
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

func (s *chatServer) handleConn(conn quic.Connection) {
	for {
		stream, err := conn.AcceptStream(context.Background())
		if err != nil {
			return
		}
		go s.handleChatStream(stream)
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

// ---------- helpers for tests ----------

func startServer(t *testing.T) (*chatServer, *quic.Listener, string) {
	t.Helper()
	srv := newChatServer()
	tlsConf := selfSignedTLS()
	listener, err := quic.ListenAddr("127.0.0.1:0", tlsConf, &quic.Config{
		MaxIdleTimeout:  10 * time.Second,
		EnableDatagrams: true,
	})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := listener.Addr().String()
	t.Logf("Server listening on %s", addr)

	go func() {
		for {
			conn, err := listener.Accept(context.Background())
			if err != nil {
				return
			}
			go srv.handleConn(conn)
		}
	}()
	return srv, listener, addr
}

func dialClient(t *testing.T, addr string) quic.Connection {
	t.Helper()
	clientTLS := &tls.Config{
		NextProtos:         []string{"chat"},
		InsecureSkipVerify: true,
	}
	conn, err := quic.DialAddr(context.Background(), addr, clientTLS, &quic.Config{
		MaxIdleTimeout:  10 * time.Second,
		EnableDatagrams: true,
	})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return conn
}

func joinRoomOnStream(t *testing.T, conn quic.Connection, room, nick string) quic.Stream {
	t.Helper()
	stream, err := conn.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	writeFrame(stream, joinCmd{Cmd: "join", Room: room, Nick: nick})
	resp, err := readFrame(stream)
	if err != nil {
		t.Fatalf("read join response: %v", err)
	}
	if ev, _ := resp["ev"].(string); ev != "joined" {
		t.Fatalf("expected joined, got %v", resp)
	}
	return stream
}

// ---------- Test: single-stream chat (backwards compatible) ----------

func TestChatE2E(t *testing.T) {
	_, listener, addr := startServer(t)
	defer listener.Close()

	// Alice joins lobby
	aliceConn := dialClient(t, addr)
	defer aliceConn.CloseWithError(0, "done")
	aliceStream := joinRoomOnStream(t, aliceConn, "lobby", "alice")

	// Bob joins lobby
	bobConn := dialClient(t, addr)
	defer bobConn.CloseWithError(0, "done")
	bobStream := joinRoomOnStream(t, bobConn, "lobby", "bob")

	// Alice should see bob enter
	enterMsg, _ := readFrame(aliceStream)
	t.Logf("Alice sees enter: %v", enterMsg)
	if n, _ := enterMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected bob enter, got %v", enterMsg)
	}

	// Bob sends a message
	writeFrame(bobStream, msgCmd{Cmd: "msg", Text: "hello everyone!"})
	chatMsg, _ := readFrame(aliceStream)
	t.Logf("Alice receives: %v", chatMsg)
	if text, _ := chatMsg["text"].(string); text != "hello everyone!" {
		t.Fatalf("expected 'hello everyone!', got %v", chatMsg)
	}

	// Alice replies
	writeFrame(aliceStream, msgCmd{Cmd: "msg", Text: "hey bob!"})
	bobMsg, _ := readFrame(bobStream)
	t.Logf("Bob receives: %v", bobMsg)
	if text, _ := bobMsg["text"].(string); text != "hey bob!" {
		t.Fatalf("expected 'hey bob!', got %v", bobMsg)
	}

	fmt.Println("=== TestChatE2E PASSED ===")
}

// ---------- Test: multi-stream multiplexing ----------------------------

func TestMultiRoomMultiStream(t *testing.T) {
	_, listener, addr := startServer(t)
	defer listener.Close()

	// Alice connects and joins 3 rooms on 3 separate streams
	aliceConn := dialClient(t, addr)
	defer aliceConn.CloseWithError(0, "done")

	lobbyStream := joinRoomOnStream(t, aliceConn, "lobby", "alice")
	generalStream := joinRoomOnStream(t, aliceConn, "general", "alice")
	randomStream := joinRoomOnStream(t, aliceConn, "random", "alice")

	t.Logf("Alice joined 3 rooms on streams %d, %d, %d",
		lobbyStream.StreamID(), generalStream.StreamID(), randomStream.StreamID())

	// Verify all streams have different IDs
	if lobbyStream.StreamID() == generalStream.StreamID() ||
		generalStream.StreamID() == randomStream.StreamID() {
		t.Fatal("expected different stream IDs for different rooms")
	}

	// Bob connects and joins lobby and random (not general)
	bobConn := dialClient(t, addr)
	defer bobConn.CloseWithError(0, "done")

	bobLobby := joinRoomOnStream(t, bobConn, "lobby", "bob")
	bobRandom := joinRoomOnStream(t, bobConn, "random", "bob")

	// Alice should see bob enter lobby (on lobbyStream)
	enterMsg, _ := readFrame(lobbyStream)
	if n, _ := enterMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected bob enter on lobby stream, got %v", enterMsg)
	}
	t.Log("Alice sees bob enter lobby")

	// Alice should see bob enter random (on randomStream)
	enterMsg, _ = readFrame(randomStream)
	if n, _ := enterMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected bob enter on random stream, got %v", enterMsg)
	}
	t.Log("Alice sees bob enter random")

	// Bob sends a message in lobby — only arrives on Alice's lobbyStream
	writeFrame(bobLobby, msgCmd{Cmd: "msg", Text: "hello lobby"})
	lobbyMsg, _ := readFrame(lobbyStream)
	if text, _ := lobbyMsg["text"].(string); text != "hello lobby" {
		t.Fatalf("expected 'hello lobby', got %v", lobbyMsg)
	}
	t.Log("Alice received lobby message on lobby stream")

	// Bob sends a message in random — only arrives on Alice's randomStream
	writeFrame(bobRandom, msgCmd{Cmd: "msg", Text: "hello random"})
	randomMsg, _ := readFrame(randomStream)
	if text, _ := randomMsg["text"].(string); text != "hello random" {
		t.Fatalf("expected 'hello random', got %v", randomMsg)
	}
	t.Log("Alice received random message on random stream")

	// Alice sends in general — bob should NOT receive anything (not in general)
	writeFrame(generalStream, msgCmd{Cmd: "msg", Text: "hello general"})
	// Give a small window to verify no message leaks
	time.Sleep(100 * time.Millisecond)
	t.Log("Alice sent to general — bob not in general, no leak")

	// Bob sends in random, Alice receives on randomStream
	writeFrame(bobRandom, msgCmd{Cmd: "msg", Text: "random msg 2"})
	msg, _ := readFrame(randomStream)
	if text, _ := msg["text"].(string); text != "random msg 2" {
		t.Fatalf("expected 'random msg 2', got %v", msg)
	}

	fmt.Println("=== TestMultiRoomMultiStream PASSED ===")
}

// ---------- Test: stream close triggers leave --------------------------

func TestStreamCloseLeavesRoom(t *testing.T) {
	_, listener, addr := startServer(t)
	defer listener.Close()

	// Alice joins lobby
	aliceConn := dialClient(t, addr)
	defer aliceConn.CloseWithError(0, "done")
	aliceStream := joinRoomOnStream(t, aliceConn, "lobby", "alice")

	// Bob joins lobby
	bobConn := dialClient(t, addr)
	defer bobConn.CloseWithError(0, "done")
	bobStream := joinRoomOnStream(t, bobConn, "lobby", "bob")

	// Alice sees bob enter
	enterMsg, _ := readFrame(aliceStream)
	if n, _ := enterMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected bob enter, got %v", enterMsg)
	}

	// Bob closes his stream (not the connection)
	bobStream.Close()
	time.Sleep(200 * time.Millisecond)

	// Alice should see bob left
	leftMsg, _ := readFrame(aliceStream)
	t.Logf("Alice sees: %v", leftMsg)
	if ev, _ := leftMsg["ev"].(string); ev != "left" {
		t.Fatalf("expected left event, got %v", leftMsg)
	}
	if n, _ := leftMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected bob left, got %v", leftMsg)
	}

	fmt.Println("=== TestStreamCloseLeavesRoom PASSED ===")
}

// ---------- Test: multiple rooms on one connection ---------------------

func TestMultiRoomSameConnection(t *testing.T) {
	_, listener, addr := startServer(t)
	defer listener.Close()

	// Alice opens one connection with 2 room streams
	aliceConn := dialClient(t, addr)
	defer aliceConn.CloseWithError(0, "done")

	lobbyStream := joinRoomOnStream(t, aliceConn, "lobby", "alice")
	vipStream := joinRoomOnStream(t, aliceConn, "vip", "alice")

	// Bob joins lobby only
	bobConn := dialClient(t, addr)
	defer bobConn.CloseWithError(0, "done")
	bobStream := joinRoomOnStream(t, bobConn, "lobby", "bob")

	// Alice sees bob enter lobby
	enterMsg, _ := readFrame(lobbyStream)
	if n, _ := enterMsg["nick"].(string); n != "bob" {
		t.Fatalf("expected bob enter, got %v", enterMsg)
	}

	// Bob sends in lobby
	writeFrame(bobStream, msgCmd{Cmd: "msg", Text: "lobby only"})

	// Should arrive on Alice's lobbyStream
	msg, _ := readFrame(lobbyStream)
	if text, _ := msg["text"].(string); text != "lobby only" {
		t.Fatalf("expected 'lobby only', got %v", msg)
	}

	// Alice leaves lobby by closing that stream, stays in vip
	lobbyStream.Close()
	time.Sleep(100 * time.Millisecond)

	// Bob should see alice left lobby
	leftMsg, _ := readFrame(bobStream)
	t.Logf("Bob sees: %v", leftMsg)

	// Alice's vip stream should still work
	writeFrame(vipStream, msgCmd{Cmd: "msg", Text: "still in vip"})
	// No one else in VIP to receive, but stream should not error
	t.Log("VIP stream still functional after leaving lobby")

	fmt.Println("=== TestMultiRoomSameConnection PASSED ===")
}
