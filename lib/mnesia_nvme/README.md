# Mnesia NVMe KV Backend

A Mnesia pluggable backend for NVMe Key-Value SSDs using the NVMe 2.0 KV command set.

## Overview

This module implements the `mnesia_backend_type` behavior to provide storage on
NVMe SSDs supporting the Key-Value command set (NVMe 2.0+). It uses Linux
io_uring passthrough for high-performance, zero-copy access to NVMe KV commands.

## Features

- **NVMe KV Command Set**: Store, Retrieve, Delete, Exist, List operations
- **io_uring Passthrough**: Zero-copy command submission (Linux 5.19+)
- **Mock Backend**: ETS-based simulation for development/testing
- **Full Mnesia Integration**: Transactions, replication, schema operations

## Architecture

```
┌─────────────────────────────────────────┐
│            Mnesia Application           │
├─────────────────────────────────────────┤
│        mnesia_nvme_backend.erl          │
│    (mnesia_backend_type behavior)       │
├─────────────────────────────────────────┤
│        mnesia_nvme_device.erl           │
│      (Backend selection layer)          │
├────────────────┬────────────────────────┤
│ mnesia_nvme_nif│  mnesia_nvme_mock.erl │
│ (io_uring NIF) │  (ETS simulation)      │
├────────────────┴────────────────────────┤
│  /dev/ngXnY    │     ETS tables         │
│  (NVMe char)   │   (development)        │
└────────────────┴────────────────────────┘
```

## Usage

```erlang
%% Register the backend
{atomic, ok} = mnesia:add_backend_type(nvme_kv_copies, mnesia_nvme_backend).

%% Create a table using the backend
{atomic, ok} = mnesia:create_table(my_table, [
    {attributes, [id, name, data]},
    {type, set},
    {nvme_kv_copies, [node()]}
]).

%% Use normally with Mnesia transactions
mnesia:transaction(fun() ->
    mnesia:write({my_table, 1, "Alice", <<"data">>}),
    mnesia:read(my_table, 1)
end).
```

## Configuration

```erlang
%% Application environment
{mnesia_nvme, [
    {device_path, "/dev/ng0n1"},   % NVMe generic char device
    {backend, nif},                 % nif | mock
    {queue_depth, 64},              % io_uring queue depth
    {max_key_size, 16},             % NVMe KV max key size (bytes)
    {max_value_size, 2097152}       % Max value size (2MB)
]}.
```

## Building

```bash
# Build Erlang modules
cd lib/mnesia_nvme
make compile

# Build NIF (requires liburing-dev)
make nif
```

## Testing

### Mock Backend Tests (Verified)

The mock backend has been tested and verified with full Mnesia integration:

```bash
# Compile the Erlang modules
cd lib/mnesia_nvme
make erlang

# Run a quick test
erl -pa ebin -noshell -eval '
application:set_env(mnesia_nvme, backend, mock),
{ok, H} = mnesia_nvme_mock:open("/dev/mock"),
ok = mnesia_nvme_mock:store(H, 1, <<"key">>, <<"value">>),
{ok, <<"value">>} = mnesia_nvme_mock:retrieve(H, 1, <<"key">>),
io:format("Mock backend works!~n"),
init:stop(0).
'
```

The following operations are tested and working with the mock backend:
- Store/Retrieve key-value pairs
- Delete operations
- Exists checks
- List keys with prefix filtering
- Full Mnesia backend integration (transactions, insert, lookup, delete, select)

### NIF Testing (Real NVMe Hardware)

The NIF requires:
- Linux kernel 5.19+ with io_uring passthrough support
- liburing-dev for compilation
- NVMe device with KV command set support (rare in consumer SSDs)

```bash
# Build NIF (if liburing is available)
make nif
```

### With NVMeVirt (QEMU)

For testing without real hardware, use [NVMeVirt](https://github.com/snu-csl/nvmevirt)
which is a Linux kernel module that emulates NVMe devices with KV support.

See `scripts/setup_qemu_nvmevirt.sh` for QEMU VM setup instructions.

Requirements for NVMeVirt testing:
1. QEMU with NVMe support
2. Linux VM with kernel headers and build tools
3. NVMeVirt compiled with `CONFIG_NVMEVIRT_KV := y`
4. Load module with: `insmod nvmev.ko memmap_start=1G memmap_size=512M cpus=2,3`

## NVMe KV Command Set

Supported commands from NVMe KV Spec 1.1:

| Command  | Opcode | Description              |
|----------|--------|--------------------------|
| Store    | 0x01   | Store key-value pair     |
| Retrieve | 0x02   | Get value by key         |
| Delete   | 0x10   | Remove key-value pair    |
| Exist    | 0x14   | Check if key exists      |
| List     | 0x06   | Iterate keys with prefix |

## Key Format

Keys are stored as:
```
<<TableHashPrefix:4/bytes, erlang:term_to_binary(Key)/binary>>
```

This allows efficient table-scoped operations on the KV device.

## Requirements

- **Hardware**: NVMe SSD with KV command set support, or
- **Emulation**: NVMeVirt kernel module with KV mode
- **Linux**: Kernel 5.19+ for io_uring passthrough
- **Libraries**: liburing-dev for NIF compilation

## References

- [NVMe KV Command Set Spec 1.1](https://nvmexpress.org/specification/key-value-command-set-specification/)
- [NVMeVirt](https://github.com/snu-csl/nvmevirt) - Software NVMe device emulation
- [io_uring Passthrough](https://www.usenix.org/system/files/fast24-joshi.pdf) - FAST'24 paper

## License

Apache License 2.0
