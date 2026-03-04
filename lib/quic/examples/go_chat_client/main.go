// QUIC Chat Client
//
// Interactive chat client that connects to the Erlang quic_chat_server.
// Uses length-prefixed JSON frames over a single QUIC bidirectional stream.
//
// Usage:
//   go run main.go --addr localhost:4433 --nick alice --room lobby

package main

import (
	"bufio"
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

	"github.com/quic-go/quic-go"
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
	if length > 1<<20 { // 1 MB sanity limit
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

// --- Main --------------------------------------------------------------

func main() {
	addr := flag.String("addr", "localhost:4433", "Server address")
	nick := flag.String("nick", "", "Your nickname (required)")
	room := flag.String("room", "lobby", "Room to join")
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

	fmt.Printf("Connecting to %s as %s ...\n", *addr, *nick)
	conn, err := quic.DialAddr(ctx, *addr, tlsConf, quicConf)
	if err != nil {
		log.Fatalf("Connect failed: %v", err)
	}
	defer conn.CloseWithError(0, "bye")

	// Open a single bidirectional control stream
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		log.Fatalf("Open stream failed: %v", err)
	}

	fmt.Printf("Connected! Joining room %q ...\n", *room)

	// Join the room
	if err := writeFrame(stream, joinCmd{Cmd: "join", Room: *room, Nick: *nick}); err != nil {
		log.Fatalf("Join failed: %v", err)
	}

	// Wait for the joined confirmation
	resp, err := readFrame(stream)
	if err != nil {
		log.Fatalf("Read joined response: %v", err)
	}
	if ev, _ := resp["ev"].(string); ev == "joined" {
		members, _ := resp["members"].([]any)
		if len(members) == 0 {
			fmt.Println("Joined! You're the first one here.")
		} else {
			names := make([]string, len(members))
			for i, m := range members {
				names[i], _ = m.(string)
			}
			fmt.Printf("Joined! Members already here: %s\n", strings.Join(names, ", "))
		}
	} else {
		fmt.Printf("Unexpected response: %v\n", resp)
	}

	fmt.Println("Type messages and press Enter to send. /quit to exit, /join <room> to switch rooms.")
	fmt.Println("---")

	// Receive loop in background
	var wg sync.WaitGroup
	done := make(chan struct{})

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			msg, err := readFrame(stream)
			if err != nil {
				select {
				case <-done:
					return
				default:
					log.Printf("Read error: %v", err)
					return
				}
			}
			ev, _ := msg["ev"].(string)
			switch ev {
			case "msg":
				msgNick, _ := msg["nick"].(string)
				text, _ := msg["text"].(string)
				fmt.Printf("<%s> %s\n", msgNick, text)
			case "enter":
				enterNick, _ := msg["nick"].(string)
				fmt.Printf("* %s joined the room\n", enterNick)
			case "left":
				leftNick, _ := msg["nick"].(string)
				fmt.Printf("* %s left the room\n", leftNick)
			case "joined":
				members, _ := msg["members"].([]any)
				names := make([]string, len(members))
				for i, m := range members {
					names[i], _ = m.(string)
				}
				if len(names) == 0 {
					fmt.Println("Joined! You're the first one here.")
				} else {
					fmt.Printf("Joined! Members already here: %s\n", strings.Join(names, ", "))
				}
			case "left_ok":
				fmt.Println("Left room.")
			case "error":
				text, _ := msg["text"].(string)
				fmt.Printf("[error] %s\n", text)
			default:
				fmt.Printf("[server] %v\n", msg)
			}
		}
	}()

	// Input loop
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if line == "/quit" {
			_ = writeFrame(stream, leaveCmd{Cmd: "leave"})
			break
		}
		if strings.HasPrefix(line, "/join ") {
			parts := strings.SplitN(line, " ", 2)
			if len(parts) == 2 && parts[1] != "" {
				newRoom := strings.TrimSpace(parts[1])
				fmt.Printf("Switching to room %q ...\n", newRoom)
				_ = writeFrame(stream, joinCmd{Cmd: "join", Room: newRoom, Nick: *nick})
				continue
			}
		}
		// Regular chat message
		if err := writeFrame(stream, msgCmd{Cmd: "msg", Text: line}); err != nil {
			log.Printf("Send failed: %v", err)
			break
		}
	}

	close(done)
	stream.Close()
	wg.Wait()
	fmt.Println("Goodbye!")
}
