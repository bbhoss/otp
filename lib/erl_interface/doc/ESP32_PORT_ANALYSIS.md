# erl_interface ESP32 Port Analysis

This document summarizes the analysis and proof-of-concept port of erl_interface to the ESP32 microcontroller platform using ESP-IDF v5.2.2.

## Summary

The erl_interface C library can be successfully ported to ESP32 with moderate effort. A working prototype was created that:

1. Encodes/decodes Erlang external term format
2. Connects to an Erlang node using `ei_connect_host_port()` (bypassing EPMD)
3. Sends messages to registered processes using `ei_reg_send()`

## Key Modifications Required

### 1. Platform Detection and Configuration (`config.h`)

Create an ESP32-specific `config.h` with:
- `ESP_PLATFORM=1` marker
- `EI_NO_EPMD=1` - skip EPMD lookups
- `EI_NO_COOKIE_FILE=1` - no filesystem for cookie
- Disable `_REENTRANT` - single-threaded environment
- 32-bit type sizes (`SIZEOF_LONG=4`, `SIZEOF_VOID_P=4`, etc.)
- lwIP BSD socket compatibility flags

### 2. POSIX Incompatibilities Fixed

| Issue | Location | Fix |
|-------|----------|-----|
| `sys/utsname.h` not available | `ei_connect_int.h`, `ei_connect.c` | Guard with `#ifndef ESP_PLATFORM` |
| `gethostname()` missing | `ei_connect.c` | Provide stub returning fixed hostname |
| `gethostbyaddr()` missing | `ei_resolve.c` | Provide stub returning NULL |
| `h_errno` duplicate definition | `ei_resolve.c` | Guard with `#ifndef ESP_PLATFORM` |

### 3. Symbol Conflicts with lwIP

The erl_interface uses function names that conflict with lwIP's TCP API:

| Original | Renamed to |
|----------|------------|
| `tcp_write()` | `ei_tcp_write()` |
| `tcp_read()` | `ei_tcp_read()` |
| `tcp_close()` | `ei_tcp_close()` |
| `tcp_accept()` | `ei_tcp_accept()` |
| `tcp_listen()` | `ei_tcp_listen()` |
| `tcp_connect()` | `ei_tcp_connect()` |

Changes in `ei_portio.c` and all callers.

### 4. MD5 Implementation

Original code uses OpenSSL MD5 (`openssl/md5.h`). For ESP32:

```c
#if defined(ESP_PLATFORM)
#include "mbedtls/md5.h"
typedef mbedtls_md5_context MD5_CTX;
static inline void ei_MD5Init(MD5_CTX *ctx) {
    mbedtls_md5_init(ctx);
    mbedtls_md5_starts(ctx);
}
// ... other MD5 wrappers
#endif
```

### 5. Random Number Generation

Replace `time()` and other entropy sources with ESP32's hardware RNG:

```c
#ifdef ESP_PLATFORM
#include "esp_random.h"
static unsigned int gen_challenge(void) {
    return esp_random();
}
#endif
```

### 6. Error Number Handling

Add global `__erl_errno` for non-reentrant builds:
```c
volatile int __erl_errno = 0;
```

### 7. Stack Size Requirements

The distribution protocol handshake requires significant stack space. Main task stack should be at least 16KB:

```
CONFIG_ESP_MAIN_TASK_STACK_SIZE=16384
```

## Files Modified/Created

**ESP32-specific additions:**
- `include/config.h` - Platform configuration
- `src/ei_esp32.c` - ESP32 stubs (`gethostname`, `__erl_errno`)

**Core files modified:**
- `src/ei_connect.c` - POSIX guards, `gen_challenge()` for ESP32
- `src/ei_connect_int.h` - utsname guard
- `src/ei_portio.c` - Renamed TCP functions
- `src/ei_resolve.c` - `h_errno` and `gethostbyaddr` guards
- `include/erl_md5.h` - mbedTLS support

## Source Files Needed

Core distribution:
- `ei_connect.c`, `ei_portio.c`, `ei_resolve.c`
- `ei_malloc.c`, `ei_locking.c`, `ei_format.c`
- `ei_printterm.c`, `ei_trace.c`, `ei_decode_term.c`
- `get_type.c`, `show_msg.c`
- `eirecv.c`, `send.c`, `send_reg.c`, `send_exit.c`
- `ei_x_encode.c`

Encoders (encode_*.c):
- atom, big, bignum, binary, boolean, char, double
- fun, list_header, long, longlong, pid, port, ref
- string, trace, tuple_header, ulong, ulonglong, version

Decoders (decode_*.c):
- atom, big, bignum, binary, boolean, char, double
- fun, intlist, iodata, list_header, long, longlong
- pid, port, ref, skip, string, trace, tuple_header
- ulong, ulonglong, version

## ESP-IDF Component Dependencies

```cmake
REQUIRES lwip mbedtls esp_system
```

## Test Results

Successfully tested in QEMU ESP32 emulation:
1. Erlang term encoding: `{hello, "world", 42}` encoded correctly
2. TCP connection to host Erlang node on port 9000
3. Message `{hello_from_esp32, <pid>}` received by Erlang process

## IPv6 Status

The current erl_interface implementation is IPv4-only. IPv6 support would require modifications to:
- `ei_connect.c` - socket creation and address handling
- `ei_resolve.c` - name resolution
- Distribution protocol handshake (node name format)

## Recommendations for Upstream

1. Add `EI_PLATFORM_ESP32` configuration option
2. Make TCP function names configurable via macros
3. Add socket abstraction layer (`ei_socket_callbacks`) for custom implementations
4. Consider optional IPv6 support
5. Reduce stack usage in handshake code

## Memory Usage

- Binary size: ~375 KB (with all encoders/decoders)
- Heap usage during connection: ~100 KB peak (with dynamic allocation)
- Static pool usage: ~15 KB peak (with static allocation mode)
- Could be reduced by excluding unused encoders/decoders

## Static Memory Allocation Mode

For embedded systems that cannot use dynamic memory allocation (no heap, or deterministic memory requirements), a static pool allocator can replace `malloc`/`realloc`/`free`.

### Configuration

Add to `config.h`:
```c
/* Use simple socket info array instead of segment-based allocation.
 * The segment-based approach allocates ~90KB per segment which is
 * too much for embedded systems with static memory pools. */
#define EI_DISABLE_SEQ_SOCKET_INFO 1
```

### Static Pool Implementation (`ei_malloc.c`)

Replace the standard malloc wrapper with a bump allocator:

```c
/*
 * Pool must be large enough for:
 * - 1 socket info array (5 * ~3KB = ~15KB)
 * - ei_x_buff message buffers (~2KB each)
 * - Other small allocations
 */
#define EI_POOL_SIZE      20480  /* 20KB total pool size */
#define EI_MAX_ALLOCS     16     /* Maximum concurrent allocations */

static char ei_pool[EI_POOL_SIZE] __attribute__((aligned(4)));
static size_t ei_pool_used = 0;

/* Allocation tracking for realloc/free */
typedef struct {
    void *ptr;
    size_t size;
} ei_alloc_entry;

static ei_alloc_entry ei_allocs[EI_MAX_ALLOCS];
static int ei_alloc_count = 0;

void* ei_malloc(long size) {
    size_t aligned_size = (size + 3) & ~3;  /* 4-byte alignment */
    if (ei_pool_used + aligned_size > EI_POOL_SIZE) return NULL;
    if (ei_alloc_count >= EI_MAX_ALLOCS) return NULL;

    void *ptr = &ei_pool[ei_pool_used];
    ei_pool_used += aligned_size;

    ei_allocs[ei_alloc_count].ptr = ptr;
    ei_allocs[ei_alloc_count].size = size;
    ei_alloc_count++;
    return ptr;
}

void* ei_realloc(void *orig, long size) {
    if (orig == NULL) return ei_malloc(size);
    /* Allocate new block, copy data, mark old as freed */
    /* ... */
}

void ei_free(void *ptr) {
    /* Mark allocation as freed (memory not returned to pool) */
    /* ... */
}

void ei_pool_reset(void) {
    ei_pool_used = 0;
    ei_alloc_count = 0;
}
```

### Why `EI_DISABLE_SEQ_SOCKET_INFO` is Required

The default socket info implementation uses a segment-based array where each segment holds 32 `ei_socket_info` structures. Each structure contains:
- Full `ei_cnode` copy (~1.1 KB with node names)
- Cookie buffer (513 bytes)
- Socket state (~16 bytes)

Total per entry: ~3 KB
Segment size: 32 × 3 KB ≈ **96 KB per segment**

This is far too large for embedded static pools. The `EI_DISABLE_SEQ_SOCKET_INFO` flag enables a simpler implementation that allocates a growable array of 5 entries at a time (~15 KB), which fits within a 20 KB pool.

### Memory Usage with Static Allocation

Tested results:
```
Pool after reset:   0/20480 bytes, 0 allocs
Pool after xinit:   0/20480 bytes, 0 allocs
Pool after connect: 14320/20480 bytes, 1 allocs  (socket info array)
```

### Lifecycle Management

For single-connection embedded use:
1. Call `ei_pool_reset()` before each connection attempt
2. Use connection normally
3. After disconnect, call `ei_pool_reset()` to reclaim all memory

The bump allocator never truly frees memory - it marks allocations as freed for `realloc` tracking, but the pool is only reset in full by `ei_pool_reset()`.

### Trade-offs

| Aspect | Dynamic Allocation | Static Pool |
|--------|-------------------|-------------|
| Memory overhead | Per-allocation headers | Fixed pool + tracking array |
| Fragmentation | Possible | None (bump allocator) |
| Peak usage | ~100 KB | ~15 KB (configurable) |
| Multiple connections | Unlimited | Limited by pool size |
| Free behavior | Immediate | Deferred until reset |
| Determinism | Variable | Constant time |
