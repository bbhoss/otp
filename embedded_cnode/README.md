# Embedded C-Node Demo

This directory contains a demonstration of an ESP32 microcontroller communicating
with an Erlang node using the Erlang distribution protocol. The ESP32 acts as
a C-node, enabling bidirectional message passing with standard Erlang processes.

## Overview

The demo implements a ping-pong protocol where:
1. ESP32 sends `{ping, RandomNumber, Pid}` to the Erlang node
2. Erlang receives the message and replies with `{pong, RandomNumber}`
3. ESP32 verifies the number matches
4. This repeats for 10 rounds

## Directory Structure

```
embedded_cnode/
├── README.md                 # This file
├── esp32_rust_demo/          # ESP32 Rust application
│   ├── Cargo.toml            # Rust dependencies
│   ├── build.rs              # Build script for ESP-IDF
│   ├── sdkconfig.defaults    # ESP-IDF configuration
│   ├── .cargo/
│   │   └── config.toml       # Cargo target configuration
│   └── src/
│       └── main.rs           # Main application
└── erlang_handler/
    └── esp_handler.erl       # Erlang ping-pong handler
```

## Prerequisites

### For ESP32 Development
- ESP-RS toolchain: https://github.com/esp-rs/espup
- ESP-IDF v5.2

Install the toolchain:
```bash
cargo install espup ldproxy
espup install --targets esp32
source ~/.espressif/esp-idf/v5.2/export.sh
```

### For QEMU Testing
- QEMU with ESP32 support (custom build with OpenCores Ethernet)
- Standard Erlang/OTP installation

## Running the Demo

### 1. Start the Erlang Handler

```bash
cd erlang_handler
erlc esp_handler.erl
erl -sname erlhost -setcookie testcookie \
    -kernel inet_dist_listen_min 9000 inet_dist_listen_max 9000 \
    -noshell -s esp_handler start
```

### 2. Build and Run the ESP32 Demo

#### Option A: Real Hardware
```bash
cd esp32_rust_demo
cargo run --release
```

#### Option B: QEMU Emulation
```bash
cd esp32_rust_demo
cargo build --release

# Create flash image
cd target/xtensa-esp32-espidf/release
esptool.py --chip esp32 elf2image --flash_mode dio --flash_freq 40m \
    --flash_size 4MB esp32-rust-node -o esp32-rust-node.bin
esptool.py --chip esp32 merge_bin -o flash_image.bin --flash_mode dio \
    --flash_freq 40m --flash_size 4MB \
    0x1000 bootloader.bin 0x8000 partition-table.bin 0x10000 esp32-rust-node.bin
cp flash_image.bin flash_4mb.bin
truncate -s 4M flash_4mb.bin

# Run in QEMU (requires ESP32-capable QEMU)
qemu-system-xtensa -machine esp32 -nographic \
    -drive file=flash_4mb.bin,if=mtd,format=raw \
    -nic user,model=open_eth,hostfwd=tcp::2222-:22
```

## Expected Output

### Erlang Side
```
Starting ESP32 ping-pong handler...
Handler registered as 'esp_handler'
Waiting for ping messages from ESP32...
Received: {ping, 1301} from <8950.0.0>
Sending:  {pong, 1301}
Received: {ping, 24842} from <8950.2.0>
Sending:  {pong, 24842}
...
```

### ESP32 Side
```
I (3928) esp32_rust_node: Successfully connected to Erlang node!
I (3928) esp32_rust_node: [Round 1] Sending: {ping, 1301}
I (3948) esp32_rust_node: [Round 1] Received: {pong, 1301} - OK!
I (3958) esp32_rust_node: [Round 2] Sending: {ping, 24842}
I (3958) esp32_rust_node: [Round 2] Received: {pong, 24842} - OK!
...
I (3998) esp32_rust_node: Ping-pong complete: 10/10 successful rounds
```

## Network Configuration

### QEMU User-Mode Networking
- ESP32 IP: 10.0.2.15 (via DHCP)
- Host gateway: 10.0.2.2
- Erlang node listens on port 9000

### Real Hardware
Modify `ERLANG_HOST` and `ERLANG_PORT` in `src/main.rs` to match your network
configuration.

## The erlang_node Library

The ESP32 demo uses the `erlang_node` library located at:
`lib/erl_interface/examples/esp32_rust_node/`

This is a clean-room Rust implementation of the Erlang distribution protocol,
designed for embedded systems. It supports:
- Erlang distribution handshake (version 6)
- MD5 cookie authentication
- Erlang External Term Format encoding/decoding
- Message sending to registered processes
- Message receiving

## License

Apache-2.0
