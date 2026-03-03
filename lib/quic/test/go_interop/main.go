// QUIC Interop Test Tool
//
// This Go program provides echo server and client modes for testing
// the Erlang QUIC implementation against a production QUIC stack (quic-go).
//
// Usage:
//   go run main.go server --port 4433 --cert cert.pem --key key.pem
//   go run main.go client --addr localhost:4433 --insecure

package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: go run main.go <server|client> [options]")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "server":
		runServer(os.Args[2:])
	case "client":
		runClient(os.Args[2:])
	default:
		fmt.Printf("Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}

func runServer(args []string) {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	port := fs.Int("port", 4433, "Listen port")
	certFile := fs.String("cert", "cert.pem", "Certificate file")
	keyFile := fs.String("key", "key.pem", "Key file")
	fs.Parse(args)

	cert, err := tls.LoadX509KeyPair(*certFile, *keyFile)
	if err != nil {
		log.Fatalf("Failed to load certificate: %v", err)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"echo", "test", "h3"},
	}

	quicConfig := &quic.Config{
		MaxIdleTimeout:  30 * time.Second,
		Allow0RTT:       true,
		EnableDatagrams: true,
	}

	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	listener, err := quic.ListenAddr(addr, tlsConfig, quicConfig)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	defer listener.Close()

	fmt.Printf("QUIC echo server listening on %s\n", addr)

	for {
		conn, err := listener.Accept(context.Background())
		if err != nil {
			log.Printf("Accept error: %v", err)
			continue
		}
		fmt.Printf("New connection from %s (ALPN: %s)\n",
			conn.RemoteAddr(), conn.ConnectionState().TLS.NegotiatedProtocol)
		go handleConnection(conn)
	}
}

func handleConnection(conn quic.Connection) {
	defer func() {
		conn.CloseWithError(0, "done")
		fmt.Printf("Connection closed: %s\n", conn.RemoteAddr())
	}()

	// Handle datagrams in background
	go handleDatagrams(conn)

	for {
		stream, err := conn.AcceptStream(context.Background())
		if err != nil {
			log.Printf("AcceptStream error: %v", err)
			return
		}
		fmt.Printf("New stream %d from %s\n", stream.StreamID(), conn.RemoteAddr())
		go handleStream(stream)
	}
}

func handleStream(stream quic.Stream) {
	defer stream.Close()

	buf := make([]byte, 65536)
	for {
		n, err := stream.Read(buf)
		if n > 0 {
			data := buf[:n]
			fmt.Printf("Stream %d received %d bytes: %q\n", stream.StreamID(), n, data)

			// Echo back
			_, writeErr := stream.Write(data)
			if writeErr != nil {
				log.Printf("Stream %d write error: %v", stream.StreamID(), writeErr)
				return
			}
			fmt.Printf("Stream %d echoed %d bytes\n", stream.StreamID(), n)
		}
		if err != nil {
			if err != io.EOF {
				log.Printf("Stream %d read error: %v", stream.StreamID(), err)
			}
			return
		}
	}
}

func handleDatagrams(conn quic.Connection) {
	for {
		data, err := conn.ReceiveDatagram(context.Background())
		if err != nil {
			return
		}
		fmt.Printf("Received datagram: %q\n", data)
		// Echo back
		err = conn.SendDatagram(data)
		if err != nil {
			log.Printf("Datagram send error: %v", err)
		}
	}
}

func runClient(args []string) {
	fs := flag.NewFlagSet("client", flag.ExitOnError)
	addr := fs.String("addr", "localhost:4433", "Server address")
	alpn := fs.String("alpn", "echo", "ALPN protocol")
	insecure := fs.Bool("insecure", false, "Skip certificate verification")
	message := fs.String("msg", "Hello from Go QUIC client!", "Message to send")
	fs.Parse(args)

	tlsConfig := &tls.Config{
		NextProtos:         []string{*alpn},
		InsecureSkipVerify: *insecure,
	}

	quicConfig := &quic.Config{
		MaxIdleTimeout:  30 * time.Second,
		EnableDatagrams: true,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	fmt.Printf("Connecting to %s (ALPN: %s)\n", *addr, *alpn)
	conn, err := quic.DialAddr(ctx, *addr, tlsConfig, quicConfig)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.CloseWithError(0, "done")

	fmt.Printf("Connected! ALPN: %s\n",
		conn.ConnectionState().TLS.NegotiatedProtocol)

	// Open a stream
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}

	// Send message
	msgBytes := []byte(*message)
	_, err = stream.Write(msgBytes)
	if err != nil {
		log.Fatalf("Failed to send: %v", err)
	}
	fmt.Printf("Sent %d bytes: %q\n", len(msgBytes), *message)

	// Read echo
	buf := make([]byte, len(msgBytes))
	n, err := io.ReadFull(stream, buf)
	if err != nil {
		log.Fatalf("Failed to receive echo: %v", err)
	}

	echo := string(buf[:n])
	fmt.Printf("Received echo: %q (%d bytes)\n", echo, n)

	if echo == *message {
		fmt.Println("SUCCESS: Echo matched!")
	} else {
		fmt.Println("FAILURE: Echo did not match!")
		os.Exit(1)
	}

	// Test datagram if supported
	dgData := []byte("datagram-ping")
	err = conn.SendDatagram(dgData)
	if err != nil {
		fmt.Printf("Datagram send: %v (may not be supported)\n", err)
	} else {
		fmt.Printf("Sent datagram: %q\n", dgData)
		dgCtx, dgCancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer dgCancel()
		resp, err := conn.ReceiveDatagram(dgCtx)
		if err != nil {
			fmt.Printf("Datagram receive: %v\n", err)
		} else {
			fmt.Printf("Received datagram echo: %q\n", resp)
		}
	}

	stream.Close()
	fmt.Println("Client done.")
}
