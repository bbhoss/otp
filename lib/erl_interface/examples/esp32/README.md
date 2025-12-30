# erl_interface ESP32 Port Example

This is a proof-of-concept port of erl_interface to the ESP32 microcontroller
using ESP-IDF v5.2.2.

## Prerequisites

1. ESP-IDF v5.2.2 installed (`git clone -b v5.2.2 --depth 1 https://github.com/espressif/esp-idf.git`)
2. QEMU for ESP32 (for testing: `git clone https://github.com/espressif/qemu.git`)
3. Erlang/OTP installed on host

## Building

```bash
# Set up ESP-IDF environment
source /path/to/esp-idf/export.sh

# Build the project
cd examples/esp32
idf.py build
```

## Testing with QEMU

1. Create flash image:
```bash
dd if=/dev/zero bs=1M count=4 of=build/flash_image.bin
dd if=build/bootloader/bootloader.bin of=build/flash_image.bin bs=1 seek=$((0x1000)) conv=notrunc
dd if=build/partition_table/partition-table.bin of=build/flash_image.bin bs=1 seek=$((0x8000)) conv=notrunc
dd if=build/esp_erlang_node.bin of=build/flash_image.bin bs=1 seek=$((0x10000)) conv=notrunc
```

2. Start the Erlang receiver on host:
```bash
cd examples/esp32
erlc esp_receiver.erl
erl -sname erlnode -setcookie testcookie \
    -kernel inet_dist_listen_min 9000 inet_dist_listen_max 9000 \
    -s esp_receiver start -noshell
```

3. Run ESP32 in QEMU:
```bash
qemu-system-xtensa -M esp32 -nographic \
    -drive file=build/flash_image.bin,if=mtd,format=raw \
    -nic user,model=open_eth
```

You should see the Erlang node receive `{hello_from_esp32, <pid>}` from the ESP32.

## What's Included

- `main/main.c` - ESP32 C node that connects to Erlang and sends a message
- `components/erl_interface/` - Ported erl_interface library
- `components/emul_ip/` - QEMU OpenCores Ethernet driver
- `esp_receiver.erl` - Erlang receiver module for testing

## Key Modifications

See `../doc/ESP32_PORT_ANALYSIS.md` for detailed analysis of changes required.
