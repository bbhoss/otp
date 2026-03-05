// connect_test.go - Test connectivity to Erlang QUIC chat server
//
// Run:  go test -v -run TestConnectErlang -count=1
// (Requires the Erlang chat server running on localhost:4433)

package main

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/logging"
	"github.com/quic-go/quic-go/qlog"
)

func TestConnectErlang(t *testing.T) {
	addr := os.Getenv("QUIC_ADDR")
	if addr == "" {
		addr = "127.0.0.1:4433"
	}

	keylogFile, _ := os.Create("/tmp/quic_keylog.txt")
	defer keylogFile.Close()

	clientTLS := &tls.Config{
		NextProtos:         []string{"chat"},
		InsecureSkipVerify: true,
		KeyLogWriter:       keylogFile,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	t.Logf("Dialing %s ...", addr)
	_ = log.Println  // avoid unused import
	_ = logging.PerspectiveClient
	_ = qlog.DefaultConnectionTracer
	conn, err := quic.DialAddr(ctx, addr, clientTLS, &quic.Config{
		MaxIdleTimeout:       10 * time.Second,
		EnableDatagrams:      true,
		HandshakeIdleTimeout: 5 * time.Second,
		Tracer: func(ctx context.Context, p logging.Perspective, connID quic.ConnectionID) *logging.ConnectionTracer {
			return qlog.NewConnectionTracer(os.Stderr, p, connID)
		},
	})
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseWithError(0, "done")
	t.Log("QUIC connection established!")

	// Open a stream and join lobby
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}

	// Send join command
	joinMsg := map[string]string{
		"cmd":  "join",
		"room": "lobby",
		"nick": "test_erlang",
	}
	data, _ := json.Marshal(joinMsg)
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(data)))
	stream.Write(hdr)
	stream.Write(data)
	t.Logf("Sent join command: %s", data)

	// Read response
	stream.SetReadDeadline(time.Now().Add(5 * time.Second))
	respHdr := make([]byte, 4)
	if _, err := io.ReadFull(stream, respHdr); err != nil {
		t.Fatalf("read response header: %v", err)
	}
	length := binary.BigEndian.Uint32(respHdr)
	respBody := make([]byte, length)
	if _, err := io.ReadFull(stream, respBody); err != nil {
		t.Fatalf("read response body: %v", err)
	}

	var resp map[string]any
	json.Unmarshal(respBody, &resp)
	t.Logf("Received response: %v", resp)

	if ev, _ := resp["ev"].(string); ev != "joined" {
		t.Fatalf("expected 'joined' event, got: %v", resp)
	}

	fmt.Println("=== TestConnectErlang PASSED ===")
}
