# MQuickJS - Erlang/OTP Integration with Micro QuickJS

This module provides an Erlang interface to the [MQuickJS](https://github.com/bellard/mquickjs) JavaScript engine using erl_interface/C nodes.

## Overview

MQuickJS (Micro QuickJS) is a lightweight JavaScript engine designed for embedded systems with severe resource constraints:
- Memory footprint: As little as 10 kB of RAM
- ROM footprint: ~100 kB of ROM
- ES5-compatible JavaScript with strict mode

## Building

### Prerequisites

1. Clone MQuickJS alongside this project:
   ```bash
   cd /home/user
   git clone https://github.com/bellard/mquickjs.git
   ```

2. Build the OTP erl_interface library:
   ```bash
   cd /home/user/otp
   ./configure
   cd lib/erl_interface
   make
   ```

### Build the Integration

```bash
cd /home/user/otp/lib/mquickjs
make
```

This will build:
- The MQuickJS library (in /home/user/mquickjs)
- The C node executable (`priv/mquickjs_cnode`)
- The Erlang module (`ebin/mquickjs.beam`) - requires erlc

## Usage

### From Erlang

```erlang
%% Start the JavaScript engine
{ok, Pid} = mquickjs:start_link().

%% Evaluate JavaScript code
{ok, 42} = mquickjs:eval(Pid, "21 + 21").
{ok, <<"hello">>} = mquickjs:eval(Pid, "'hello'").
{ok, true} = mquickjs:eval(Pid, "1 < 2").

%% Execute code with console output
{ok, undefined} = mquickjs:eval(Pid, "print('Hello, World!')").
{ok, <<"Hello, World!\n">>} = mquickjs:get_output(Pid).

%% Trigger garbage collection
ok = mquickjs:gc(Pid).

%% Reset the JavaScript context (with optional memory size in KB)
ok = mquickjs:reset(Pid).
ok = mquickjs:reset(Pid, 512).  %% 512KB

%% Stop the engine
ok = mquickjs:stop(Pid).
```

### Type Conversions

| JavaScript Type | Erlang Type |
|-----------------|-------------|
| number (integer) | integer |
| number (float) | float |
| string | binary |
| boolean | atom (true/false) |
| null | atom (null) |
| undefined | atom (undefined) |
| object/array | binary (string representation) |

### Options

When starting the server, you can pass options:

```erlang
mquickjs:start_link([
    {mem_size, 512},    %% JavaScript memory size in KB (default: 256)
    {name, my_js}       %% Register with a name
]).
```

## Architecture

The integration uses the erl_interface/C node mechanism:

```
+------------------+          +------------------+
|  Erlang Process  |  <--->   |   C Node         |
|  (mquickjs.erl)  |  dist    |  (mquickjs_cnode)|
+------------------+          +--------+---------+
                                       |
                                       v
                              +------------------+
                              |    MQuickJS      |
                              |  JS Engine       |
                              +------------------+
```

The C node:
1. Connects to the Erlang node using distributed Erlang protocol
2. Embeds the MQuickJS JavaScript engine
3. Receives commands from Erlang (eval, gc, reset, etc.)
4. Returns results encoded as Erlang terms

## C Node Command Line

The C node can be run standalone for debugging:

```bash
./priv/mquickjs_cnode -n myjs -c mycookie -e myerl@localhost -m 512
```

Options:
- `-n nodename` : Name of this C node (default: mquickjs)
- `-c cookie` : Erlang cookie (required)
- `-e erlang_node` : Erlang node to connect to (required)
- `-m memsize` : JS memory size in KB (default: 256)

## Supported JavaScript Features

MQuickJS supports ES5-compatible JavaScript including:
- Variables, functions, closures
- Objects, arrays, strings
- Math, Date, JSON, RegExp
- Error handling (try/catch)
- console.log() / print()

Not supported in C node mode:
- setTimeout/clearTimeout (async)
- load() (file loading)
- Module system

## License

Apache License, Version 2.0
