#!/usr/bin/env python3
"""
WASM Bridge - connects Erlang to wasmtime for executing WASM modules.

This script runs as an Erlang port and handles communication between
Erlang's gen_wasmserver and the wasmtime WASM runtime.

Protocol (stdin/stdout, 4-byte length prefix):
  Request:  {command, args...}
  Response: {ok, result} | {error, reason}
"""

import sys
import struct
import os

# Try to import wasmtime
try:
    from wasmtime import Store, Module, Instance, Memory, Func, FuncType, ValType
    HAS_WASMTIME = True
except ImportError:
    HAS_WASMTIME = False

# Global state
store = None
instance = None
memory = None
modules = {}  # ref -> (instance, memory)
next_ref = 1

def read_packet():
    """Read a length-prefixed packet from stdin."""
    length_bytes = sys.stdin.buffer.read(4)
    if len(length_bytes) < 4:
        return None
    length = struct.unpack('>I', length_bytes)[0]
    data = sys.stdin.buffer.read(length)
    return data

def write_packet(data):
    """Write a length-prefixed packet to stdout."""
    length = struct.pack('>I', len(data))
    sys.stdout.buffer.write(length + data)
    sys.stdout.buffer.flush()

def encode_term(term):
    """Simple ETF encoder for basic terms."""
    if term is None:
        return b'\x83d\x00\x03nil'
    elif isinstance(term, bool):
        if term:
            return b'\x83d\x00\x04true'
        else:
            return b'\x83d\x00\x05false'
    elif isinstance(term, int):
        if 0 <= term <= 255:
            return b'\x83a' + bytes([term])
        elif -2147483648 <= term <= 2147483647:
            return b'\x83b' + struct.pack('>i', term)
        else:
            # Big integer - simplified
            return b'\x83b' + struct.pack('>i', term & 0xFFFFFFFF)
    elif isinstance(term, str):
        atom_bytes = term.encode('utf-8')
        if len(atom_bytes) <= 255:
            return b'\x83d' + struct.pack('>H', len(atom_bytes)) + atom_bytes
        else:
            return b'\x83d' + struct.pack('>H', 255) + atom_bytes[:255]
    elif isinstance(term, bytes):
        return b'\x83m' + struct.pack('>I', len(term)) + term
    elif isinstance(term, tuple):
        if len(term) <= 255:
            result = b'\x83h' + bytes([len(term)])
        else:
            result = b'\x83i' + struct.pack('>I', len(term))
        for elem in term:
            encoded = encode_term(elem)
            result += encoded[1:]  # Skip version byte
        return result
    elif isinstance(term, list):
        if len(term) == 0:
            return b'\x83j'
        result = b'\x83l' + struct.pack('>I', len(term))
        for elem in term:
            encoded = encode_term(elem)
            result += encoded[1:]
        result += b'j'  # nil tail
        return result
    else:
        return b'\x83d\x00\x09undefined'

def decode_term(data, pos=0):
    """Simple ETF decoder for basic terms."""
    if pos >= len(data):
        return None, pos

    if data[pos] == 0x83:  # Version byte
        pos += 1

    tag = data[pos]
    pos += 1

    if tag == ord('a'):  # Small integer
        return data[pos], pos + 1
    elif tag == ord('b'):  # Integer
        val = struct.unpack('>i', data[pos:pos+4])[0]
        return val, pos + 4
    elif tag == ord('d'):  # Atom (old format)
        length = struct.unpack('>H', data[pos:pos+2])[0]
        pos += 2
        atom = data[pos:pos+length].decode('utf-8')
        return atom, pos + length
    elif tag == ord('s'):  # Small atom
        length = data[pos]
        pos += 1
        atom = data[pos:pos+length].decode('utf-8')
        return atom, pos + length
    elif tag == ord('w'):  # Small atom utf8
        length = data[pos]
        pos += 1
        atom = data[pos:pos+length].decode('utf-8')
        return atom, pos + length
    elif tag == ord('m'):  # Binary
        length = struct.unpack('>I', data[pos:pos+4])[0]
        pos += 4
        return data[pos:pos+length], pos + length
    elif tag == ord('h'):  # Small tuple
        arity = data[pos]
        pos += 1
        elements = []
        for _ in range(arity):
            elem, pos = decode_term(data, pos)
            elements.append(elem)
        return tuple(elements), pos
    elif tag == ord('i'):  # Large tuple
        arity = struct.unpack('>I', data[pos:pos+4])[0]
        pos += 4
        elements = []
        for _ in range(arity):
            elem, pos = decode_term(data, pos)
            elements.append(elem)
        return tuple(elements), pos
    elif tag == ord('j'):  # Empty list
        return [], pos
    elif tag == ord('l'):  # List
        length = struct.unpack('>I', data[pos:pos+4])[0]
        pos += 4
        elements = []
        for _ in range(length):
            elem, pos = decode_term(data, pos)
            elements.append(elem)
        # Skip tail (should be nil)
        if pos < len(data) and data[pos] == ord('j'):
            pos += 1
        return elements, pos
    elif tag == ord('n'):  # Small big integer
        n = data[pos]
        sign = data[pos + 1]
        pos += 2
        val = int.from_bytes(data[pos:pos+n], 'little')
        if sign:
            val = -val
        return val, pos + n
    elif tag == ord('o'):  # Large big integer
        n = struct.unpack('>I', data[pos:pos+4])[0]
        sign = data[pos + 4]
        pos += 5
        val = int.from_bytes(data[pos:pos+n], 'little')
        if sign:
            val = -val
        return val, pos + n
    else:
        return None, pos

def load_module(wasm_binary):
    """Load a WASM module and return a reference."""
    global next_ref

    if not HAS_WASMTIME:
        return ('error', 'wasmtime not installed')

    try:
        store = Store()
        module = Module(store.engine, wasm_binary)
        instance = Instance(store, module, [])

        # Get memory export
        memory = instance.exports(store).get("memory")

        # Get exports
        exports = {}
        for export in module.exports:
            if export.type.func_type is not None:
                exports[export.name] = len(export.type.func_type.params)

        ref = next_ref
        next_ref += 1
        modules[ref] = (store, instance, memory)

        return ('ok', ref, exports)
    except Exception as e:
        return ('error', str(e))

def call_function(ref, func_name, args):
    """Call a function in a loaded WASM module."""
    if ref not in modules:
        return ('error', 'invalid_reference')

    store, instance, memory = modules[ref]

    try:
        # Get the function
        func = instance.exports(store).get(func_name)
        if func is None:
            return ('error', f'function {func_name} not found')

        # For gen_wasmserver, args are ETF-encoded binaries
        # We need to write them to memory and pass pointers

        # Allocate memory for each arg
        alloc = instance.exports(store).get("wasm_alloc")
        free = instance.exports(store).get("wasm_free")

        if alloc is None:
            return ('error', 'wasm_alloc not found')

        ptrs = []
        for arg in args:
            if isinstance(arg, bytes):
                size = len(arg)
                ptr = alloc(store, size)
                # Write data to memory
                mem_data = memory.data_ptr(store)
                for i, b in enumerate(arg):
                    mem_data[ptr + i] = b
                ptrs.append((ptr, size))
            else:
                ptrs.append((0, 0))

        # Call the function based on its signature
        if func_name == "wasm_init":
            ptr, size = ptrs[0]
            result_ptr = func(store, ptr, size)
        elif func_name == "wasm_handle_call":
            req_ptr, req_size = ptrs[0]
            from_ptr, from_size = ptrs[1]
            state_ptr, state_size = ptrs[2]
            result_ptr = func(store, req_ptr, req_size, from_ptr, from_size, state_ptr, state_size)
        elif func_name == "wasm_handle_cast":
            req_ptr, req_size = ptrs[0]
            state_ptr, state_size = ptrs[1]
            result_ptr = func(store, req_ptr, req_size, state_ptr, state_size)
        elif func_name == "wasm_handle_info":
            info_ptr, info_size = ptrs[0]
            state_ptr, state_size = ptrs[1]
            result_ptr = func(store, info_ptr, info_size, state_ptr, state_size)
        elif func_name == "wasm_terminate":
            reason_ptr, reason_size = ptrs[0]
            state_ptr, state_size = ptrs[1]
            result_ptr = func(store, reason_ptr, reason_size, state_ptr, state_size)
        else:
            return ('error', f'unknown function {func_name}')

        # Read result from memory
        # Result format: first 4 bytes = length, then data
        mem_data = memory.data_ptr(store)
        result_size = int.from_bytes(bytes(mem_data[result_ptr:result_ptr+4]), 'little')
        result_data = bytes(mem_data[result_ptr+4:result_ptr+4+result_size])

        # Free allocated memory
        if free:
            for ptr, size in ptrs:
                if ptr != 0:
                    free(store, ptr, size)
            free(store, result_ptr, result_size + 4)

        return ('ok', result_data)
    except Exception as e:
        return ('error', str(e))

def unload_module(ref):
    """Unload a WASM module."""
    if ref in modules:
        del modules[ref]
    return 'ok'

def handle_command(cmd):
    """Handle a command from Erlang."""
    try:
        term, _ = decode_term(cmd)

        if not isinstance(term, tuple) or len(term) < 1:
            return encode_term(('error', 'invalid_command'))

        command = term[0]

        if command == 'load':
            wasm_binary = term[1]
            result = load_module(wasm_binary)
            return encode_term(result)

        elif command == 'call':
            ref = term[1]
            func_name = term[2]
            args = term[3]
            result = call_function(ref, func_name, args)
            return encode_term(result)

        elif command == 'unload':
            ref = term[1]
            result = unload_module(ref)
            return encode_term(result)

        elif command == 'ping':
            return encode_term(('pong', HAS_WASMTIME))

        else:
            return encode_term(('error', 'unknown_command'))

    except Exception as e:
        return encode_term(('error', str(e)))

def main():
    """Main loop - read commands from stdin, write responses to stdout."""
    while True:
        packet = read_packet()
        if packet is None:
            break

        response = handle_command(packet)
        write_packet(response)

if __name__ == '__main__':
    main()
