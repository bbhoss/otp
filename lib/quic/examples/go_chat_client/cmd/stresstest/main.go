// QUIC chat server stress test.
//
// Scenarios target specific implementation details:
//   - stampede:     N clients connect simultaneously (listener dedup, connected socket creation)
//   - churn:        rapid connect/disconnect cycles (registry release/re-claim, process cleanup)
//   - multistream:  one connection, many streams opened at once (stream mux, concurrent room joins)
//   - flood:        blast messages as fast as possible (drain_socket loop under load)
//   - rude:         abrupt disconnects — no clean close, partial writes, garbage (error paths)
//   - bigbang:      all scenarios run concurrently (everything at once)
//
// Usage:
//   go run . -scenario all
//   go run . -scenario stampede -clients 50 -msgs 100
//   go run . -scenario bigbang

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
	"math/rand/v2"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
)

func writeFrame(stream quic.Stream, msg any) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(data)))
	if _, err := stream.Write(append(hdr, data...)); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	return nil
}

func readFrame(stream quic.Stream) (map[string]any, error) {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(stream, hdr); err != nil {
		return nil, fmt.Errorf("read header: %w", err)
	}
	length := binary.BigEndian.Uint32(hdr)
	if length > 1<<20 {
		return nil, fmt.Errorf("frame too large: %d bytes", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(stream, payload); err != nil {
		return nil, fmt.Errorf("read payload (%d bytes): %w", length, err)
	}
	var msg map[string]any
	if err := json.Unmarshal(payload, &msg); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}
	return msg, nil
}

// --- Metrics ---

type Metrics struct {
	Conns       atomic.Int64
	ConnFails   atomic.Int64
	Streams     atomic.Int64
	StreamFails atomic.Int64
	MsgsSent    atomic.Int64
	MsgsRecv    atomic.Int64
	SendErrs    atomic.Int64
	RecvErrs    atomic.Int64
	Joins       atomic.Int64
	JoinFails   atomic.Int64
	Disconnects atomic.Int64
}

func (m *Metrics) Print() {
	fmt.Println("\n=== Stress Test Results ===")
	fmt.Printf("  Connections:  %d ok,  %d failed\n", m.Conns.Load(), m.ConnFails.Load())
	fmt.Printf("  Streams:      %d ok,  %d failed\n", m.Streams.Load(), m.StreamFails.Load())
	fmt.Printf("  Joins:        %d ok,  %d failed\n", m.Joins.Load(), m.JoinFails.Load())
	fmt.Printf("  Messages:     %d sent, %d recv\n", m.MsgsSent.Load(), m.MsgsRecv.Load())
	fmt.Printf("  Errors:       %d send, %d recv\n", m.SendErrs.Load(), m.RecvErrs.Load())
	fmt.Printf("  Disconnects:  %d\n", m.Disconnects.Load())
	fmt.Println()
}

var m Metrics

// --- Helpers ---

func dial(addr string, tlsConf *tls.Config, quicConf *quic.Config) (quic.Connection, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, addr, tlsConf, quicConf)
	if err != nil {
		m.ConnFails.Add(1)
		return nil, err
	}
	m.Conns.Add(1)
	return conn, nil
}

func openStream(conn quic.Connection) (quic.Stream, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		m.StreamFails.Add(1)
		return nil, err
	}
	m.Streams.Add(1)
	return stream, nil
}

func joinRoom(stream quic.Stream, nick, room string) error {
	if err := writeFrame(stream, map[string]string{"cmd": "join", "room": room, "nick": nick}); err != nil {
		m.JoinFails.Add(1)
		return err
	}
	resp, err := readFrame(stream)
	if err != nil {
		m.JoinFails.Add(1)
		return err
	}
	if ev, _ := resp["ev"].(string); ev != "joined" {
		m.JoinFails.Add(1)
		return fmt.Errorf("join rejected: %v", resp)
	}
	m.Joins.Add(1)
	return nil
}

func sendMsg(stream quic.Stream, text string) error {
	if err := writeFrame(stream, map[string]string{"cmd": "msg", "text": text}); err != nil {
		m.SendErrs.Add(1)
		return err
	}
	m.MsgsSent.Add(1)
	return nil
}

func drainReads(stream quic.Stream) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			_, err := readFrame(stream)
			if err != nil {
				return
			}
			m.MsgsRecv.Add(1)
		}
	}()
	return done
}

// --- Scenarios ---

// stampede: N clients connect simultaneously, all join the same room, send messages.
// Stresses: listener dedup (ETS insert_new), connected socket creation, handshake→established.
func stampede(addr string, n, msgsPerClient int, tlsConf *tls.Config, quicConf *quic.Config) {
	log.Printf("[stampede] %d clients, %d msgs each, same room", n, msgsPerClient)
	var wg sync.WaitGroup
	gate := make(chan struct{}) // release all at once
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			<-gate
			nick := fmt.Sprintf("stampede-%d", id)
			conn, err := dial(addr, tlsConf, quicConf)
			if err != nil {
				log.Printf("[stampede] client %d connect failed: %v", id, err)
				return
			}
			defer func() {
				conn.CloseWithError(0, "done")
				m.Disconnects.Add(1)
			}()

			stream, err := openStream(conn)
			if err != nil {
				return
			}
			if err := joinRoom(stream, nick, "stampede-room"); err != nil {
				return
			}
			drainReads(stream)
			for j := 0; j < msgsPerClient; j++ {
				if sendMsg(stream, fmt.Sprintf("%s #%d", nick, j)) != nil {
					return
				}
				time.Sleep(5 * time.Millisecond)
			}
		}(i)
	}
	close(gate) // release the stampede
	wg.Wait()
	log.Printf("[stampede] done")
}

// churn: rapidly connect, join, send one message, disconnect.
// Stresses: registry release/re-claim, process lifecycle, socket cleanup.
func churn(addr string, rounds int, tlsConf *tls.Config, quicConf *quic.Config) {
	workers := min(10, rounds)
	perWorker := rounds / workers
	log.Printf("[churn] %d rounds (%d workers × %d)", workers*perWorker, workers, perWorker)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(wid int) {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				nick := fmt.Sprintf("churn-%d-%d", wid, i)
				conn, err := dial(addr, tlsConf, quicConf)
				if err != nil {
					continue
				}
				stream, err := openStream(conn)
				if err != nil {
					conn.CloseWithError(0, "err")
					m.Disconnects.Add(1)
					continue
				}
				if joinRoom(stream, nick, "churn-room") == nil {
					sendMsg(stream, "hello and goodbye")
				}
				conn.CloseWithError(0, "churn")
				m.Disconnects.Add(1)
			}
		}(w)
	}
	wg.Wait()
	log.Printf("[churn] done")
}

// multistream: single connection opens many streams (rooms) at once.
// Stresses: stream multiplexing, concurrent accept_stream on server.
func multistream(addr string, numStreams int, tlsConf *tls.Config, quicConf *quic.Config) {
	log.Printf("[multistream] 1 connection, %d streams", numStreams)
	conn, err := dial(addr, tlsConf, quicConf)
	if err != nil {
		log.Printf("[multistream] connect failed: %v", err)
		return
	}
	defer func() {
		conn.CloseWithError(0, "done")
		m.Disconnects.Add(1)
	}()

	var wg sync.WaitGroup
	for i := 0; i < numStreams; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			room := fmt.Sprintf("multi-%d", idx)
			nick := fmt.Sprintf("multi-%d", idx)

			stream, err := openStream(conn)
			if err != nil {
				return
			}
			if joinRoom(stream, nick, room) != nil {
				return
			}
			drainReads(stream)
			for j := 0; j < 5; j++ {
				if sendMsg(stream, fmt.Sprintf("stream %d msg %d", idx, j)) != nil {
					return
				}
			}
		}(i)
	}
	wg.Wait()
	log.Printf("[multistream] done")
}

// flood: single stream, blast messages with no delay.
// Stresses: drain_socket loop, kernel buffer pressure, ACK handling.
func flood(addr string, count int, tlsConf *tls.Config, quicConf *quic.Config) {
	log.Printf("[flood] %d messages, no delay", count)
	conn, err := dial(addr, tlsConf, quicConf)
	if err != nil {
		log.Printf("[flood] connect failed: %v", err)
		return
	}
	defer func() {
		conn.CloseWithError(0, "done")
		m.Disconnects.Add(1)
	}()

	stream, err := openStream(conn)
	if err != nil {
		return
	}
	if joinRoom(stream, "flooder", "flood-room") != nil {
		return
	}
	drainReads(stream)

	start := time.Now()
	for i := 0; i < count; i++ {
		if sendMsg(stream, fmt.Sprintf("flood-%d", i)) != nil {
			break
		}
	}
	elapsed := time.Since(start)
	rate := float64(count) / elapsed.Seconds()
	log.Printf("[flood] %d msgs in %v (%.0f msg/s)", count, elapsed.Round(time.Millisecond), rate)
	stream.Close()
	time.Sleep(100 * time.Millisecond)
}

// rude: abrupt disconnects with various levels of misbehavior.
// Stresses: error paths, partial reads, process crash cleanup.
func rude(addr string, count int, tlsConf *tls.Config, quicConf *quic.Config) {
	workers := min(10, count)
	perWorker := count / workers
	log.Printf("[rude] %d abrupt disconnects (%d workers × %d)", workers*perWorker, workers, perWorker)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				conn, err := dial(addr, tlsConf, quicConf)
				if err != nil {
					continue
				}

				switch rand.IntN(4) {
				case 0:
					// connect then immediately slam the door
					conn.CloseWithError(42, "rude")
				case 1:
					// open stream, never send join, close
					if stream, err := openStream(conn); err == nil {
						stream.Close()
					}
					conn.CloseWithError(0, "rude")
				case 2:
					// send garbage length prefix
					if stream, err := openStream(conn); err == nil {
						stream.Write([]byte{0xFF, 0xFF, 0xFF, 0xFF})
						stream.Close()
					}
					conn.CloseWithError(0, "rude")
				case 3:
					// join then vanish without closing stream
					if stream, err := openStream(conn); err == nil {
						writeFrame(stream, map[string]string{"cmd": "join", "room": "rude-room", "nick": "ghost"})
						// don't read response, don't close stream, just kill connection
					}
					conn.CloseWithError(0, "rude")
				}
				m.Disconnects.Add(1)
			}
		}()
	}
	wg.Wait()
	log.Printf("[rude] done")
}

// reconnect: same nick reconnects repeatedly to the same room.
// Stresses: registry entry turnover for the same peer address.
func reconnect(addr string, rounds int, tlsConf *tls.Config, quicConf *quic.Config) {
	log.Printf("[reconnect] %d sequential reconnections, same room", rounds)
	for i := 0; i < rounds; i++ {
		conn, err := dial(addr, tlsConf, quicConf)
		if err != nil {
			continue
		}
		stream, err := openStream(conn)
		if err != nil {
			conn.CloseWithError(0, "err")
			m.Disconnects.Add(1)
			continue
		}
		if joinRoom(stream, "phoenix", "reconnect-room") == nil {
			for j := 0; j < 3; j++ {
				sendMsg(stream, fmt.Sprintf("life %d msg %d", i, j))
			}
			stream.Close()
		}
		conn.CloseWithError(0, "reconnect")
		m.Disconnects.Add(1)
		time.Sleep(10 * time.Millisecond)
	}
	log.Printf("[reconnect] done")
}

// bigbang: run stampede, flood, rude, and multistream all at the same time.
// Stresses: everything, concurrently.
func bigbang(addr string, tlsConf *tls.Config, quicConf *quic.Config) {
	log.Printf("[bigbang] all scenarios concurrently")
	var wg sync.WaitGroup

	run := func(name string, fn func()) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			fn()
		}()
	}

	run("stampede", func() { stampede(addr, 15, 30, tlsConf, quicConf) })
	run("churn", func() { churn(addr, 50, tlsConf, quicConf) })
	run("multistream", func() { multistream(addr, 15, tlsConf, quicConf) })
	run("flood", func() { flood(addr, 500, tlsConf, quicConf) })
	run("rude", func() { rude(addr, 30, tlsConf, quicConf) })
	run("reconnect", func() { reconnect(addr, 20, tlsConf, quicConf) })

	wg.Wait()
	log.Printf("[bigbang] done")
}

func main() {
	addr := flag.String("addr", "localhost:4433", "server address")
	scenario := flag.String("scenario", "all", "stampede|churn|multistream|flood|rude|reconnect|bigbang|all")
	clients := flag.Int("clients", 20, "concurrent clients (stampede)")
	msgs := flag.Int("msgs", 50, "messages per client (stampede)")
	rounds := flag.Int("rounds", 100, "connect/disconnect cycles (churn, reconnect)")
	streams := flag.Int("streams", 20, "streams per connection (multistream)")
	floodN := flag.Int("flood-msgs", 1000, "messages to flood")
	rudeN := flag.Int("rude-count", 50, "rude disconnects")
	flag.Parse()

	log.SetFlags(log.Ltime | log.Lmicroseconds)

	tlsConf := &tls.Config{
		NextProtos:         []string{"chat"},
		InsecureSkipVerify: true,
	}
	quicConf := &quic.Config{
		MaxIdleTimeout:  30 * time.Second,
		EnableDatagrams: true,
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)
	go func() {
		<-sigCh
		log.Println("\nInterrupted!")
		m.Print()
		os.Exit(1)
	}()

	start := time.Now()

	switch *scenario {
	case "stampede":
		stampede(*addr, *clients, *msgs, tlsConf, quicConf)
	case "churn":
		churn(*addr, *rounds, tlsConf, quicConf)
	case "multistream":
		multistream(*addr, *streams, tlsConf, quicConf)
	case "flood":
		flood(*addr, *floodN, tlsConf, quicConf)
	case "rude":
		rude(*addr, *rudeN, tlsConf, quicConf)
	case "reconnect":
		reconnect(*addr, *rounds, tlsConf, quicConf)
	case "bigbang":
		bigbang(*addr, tlsConf, quicConf)
	case "all":
		log.Println("=== Running all scenarios sequentially ===")
		stampede(*addr, *clients, *msgs, tlsConf, quicConf)
		churn(*addr, *rounds, tlsConf, quicConf)
		multistream(*addr, *streams, tlsConf, quicConf)
		flood(*addr, *floodN, tlsConf, quicConf)
		rude(*addr, *rudeN, tlsConf, quicConf)
		reconnect(*addr, *rounds, tlsConf, quicConf)
		log.Println("=== Now bigbang ===")
		bigbang(*addr, tlsConf, quicConf)
	default:
		log.Fatalf("unknown scenario: %s", *scenario)
	}

	log.Printf("Total time: %v", time.Since(start).Round(time.Millisecond))
	m.Print()
}
