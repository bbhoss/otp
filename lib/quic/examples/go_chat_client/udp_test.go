package main

import (
	"fmt"
	"net"
	"testing"
	"time"
)

func TestUDPReceive(t *testing.T) {
	// Send a raw QUIC-like Initial packet to the server and see what comes back
	serverAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:4445")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialUDP("udp", nil, serverAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	t.Logf("Local addr: %s", conn.LocalAddr())

	// Send a minimal Initial packet (will be invalid but should elicit a response)
	// Actually, let's just see if we can receive anything after the quic.DialAddr test
	// Just send some garbage and see if we get a version negotiation
	garbage := make([]byte, 1200)
	garbage[0] = 0xC0 // Long header, Initial
	// Version = 0xBABABABA (unknown)
	garbage[1] = 0xBA
	garbage[2] = 0xBA
	garbage[3] = 0xBA
	garbage[4] = 0xBA
	// DCID len = 8
	garbage[5] = 8
	// SCID len = 4
	garbage[14] = 4

	conn.Write(garbage)
	t.Log("Sent garbage packet")

	// Wait for response
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	buf := make([]byte, 4096)
	n, addr, err := conn.ReadFromUDP(buf)
	if err != nil {
		t.Logf("No response received: %v", err)
	} else {
		t.Logf("Received %d bytes from %s", n, addr)
		t.Logf("First 20 bytes: %x", buf[:min(20, n)])
	}
	fmt.Println("=== TestUDPReceive done ===")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
