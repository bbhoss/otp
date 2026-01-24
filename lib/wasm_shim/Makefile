#
# %CopyrightBegin%
#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright Ericsson AB 2024-2025. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# %CopyrightEnd%
#

# Makefile for wasm_shim library
#
# This builds:
# 1. The WASM shim library (for compiling into WASM modules)
# 2. The NIF library (for the Erlang runtime)
# 3. Erlang beam files

.PHONY: all clean wasm nif erlang examples

# Directories
SRC_DIR = src
INCLUDE_DIR = include
WIT_DIR = wit
PRIV_DIR = priv
EBIN_DIR = ebin
EXAMPLES_DIR = examples
NATIVE_DIR = native/wasm_runtime

# Compilers and tools
CC ?= gcc
ERLC ?= erlc
WASM_CC ?= clang
WASM_AR ?= llvm-ar
WIT_BINDGEN ?= wit-bindgen

# Erlang include path
ERL_INCLUDE := $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()])' -s erlang halt)/erts-*/include
EI_INCLUDE := $(shell erl -noshell -eval 'io:format("~s", [code:lib_dir(erl_interface, include)])' -s erlang halt)

# Flags for native compilation
CFLAGS = -O2 -Wall -Wextra -I$(INCLUDE_DIR) -I$(ERL_INCLUDE) -I$(EI_INCLUDE)
LDFLAGS = -shared

# Platform-specific settings
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    LDFLAGS += -dynamiclib -undefined dynamic_lookup
    NIF_EXT = .so
else
    LDFLAGS += -fPIC
    NIF_EXT = .so
    CFLAGS += -fPIC
endif

# WASM compilation flags
WASM_CFLAGS = -O2 -Wall -I$(INCLUDE_DIR) \
    --target=wasm32-wasi \
    -nostdlib \
    -Wl,--no-entry \
    -Wl,--export-dynamic

# Source files
WASM_SHIM_SRCS = $(SRC_DIR)/erl_wasm_shim.c
ERL_SRCS = $(wildcard $(SRC_DIR)/*.erl)
ERL_BEAMS = $(patsubst $(SRC_DIR)/%.erl,$(EBIN_DIR)/%.beam,$(ERL_SRCS))

# Output files
WASM_SHIM_LIB = $(PRIV_DIR)/liberl_wasm_shim.a
WASM_SHIM_WASM = $(PRIV_DIR)/erl_wasm_shim.wasm
NIF_LIB = $(PRIV_DIR)/wasm_runtime_nif$(NIF_EXT)

# Default target
all: dirs erlang

# Create output directories
dirs:
	@mkdir -p $(PRIV_DIR) $(EBIN_DIR)

# Build Erlang modules
erlang: dirs $(ERL_BEAMS)

$(EBIN_DIR)/%.beam: $(SRC_DIR)/%.erl
	$(ERLC) -o $(EBIN_DIR) -I $(INCLUDE_DIR) $<

# Build WASM shim library (for use in WASM modules)
wasm: dirs $(WASM_SHIM_LIB) $(WASM_SHIM_WASM)

$(WASM_SHIM_LIB): $(WASM_SHIM_SRCS)
	$(WASM_CC) $(WASM_CFLAGS) -c $< -o $(PRIV_DIR)/erl_wasm_shim.o
	$(WASM_AR) rcs $@ $(PRIV_DIR)/erl_wasm_shim.o
	rm -f $(PRIV_DIR)/erl_wasm_shim.o

$(WASM_SHIM_WASM): $(WASM_SHIM_SRCS)
	$(WASM_CC) $(WASM_CFLAGS) $< -o $@

# Build NIF library using Rust
nif: dirs
	cd $(NATIVE_DIR) && cargo build --release
	cp $(NATIVE_DIR)/target/release/libwasm_runtime_nif.so $(NIF_LIB) 2>/dev/null || \
	cp $(NATIVE_DIR)/target/release/libwasm_runtime_nif.dylib $(NIF_LIB) 2>/dev/null || \
	echo "Failed to copy NIF library"

# Generate WIT bindings (optional, for component model)
wit-bindings: $(WIT_DIR)/gen-wasmserver.wit
	@if command -v $(WIT_BINDGEN) >/dev/null 2>&1; then \
		$(WIT_BINDGEN) c $(WIT_DIR)/gen-wasmserver.wit --out-dir $(PRIV_DIR)/wit-bindings; \
	else \
		echo "wit-bindgen not found, skipping WIT binding generation"; \
	fi

# Build examples
examples: erlang
	@if [ -d $(EXAMPLES_DIR) ]; then \
		$(MAKE) -C $(EXAMPLES_DIR); \
	fi

# Clean build artifacts
clean:
	rm -rf $(PRIV_DIR) $(EBIN_DIR)
	cd $(NATIVE_DIR) && cargo clean 2>/dev/null || true
	@if [ -d $(EXAMPLES_DIR) ]; then \
		$(MAKE) -C $(EXAMPLES_DIR) clean; \
	fi

# Run tests
test: erlang
	@echo "Running wasm_shim tests..."
	@erl -pa $(EBIN_DIR) -noshell -eval 'eunit:test(wasm_runtime_nif, [verbose])' -s init stop

# Install to Erlang lib directory
install: all
	@echo "Installing wasm_shim..."
	@INSTALL_DIR=$(shell erl -noshell -eval 'io:format("~s", [code:lib_dir()])' -s erlang halt)/wasm_shim-1.0.0; \
	mkdir -p $$INSTALL_DIR/ebin $$INSTALL_DIR/priv $$INSTALL_DIR/include $$INSTALL_DIR/wit; \
	cp $(EBIN_DIR)/*.beam $$INSTALL_DIR/ebin/; \
	cp $(INCLUDE_DIR)/*.h $$INSTALL_DIR/include/ 2>/dev/null || true; \
	cp $(PRIV_DIR)/* $$INSTALL_DIR/priv/ 2>/dev/null || true; \
	cp $(WIT_DIR)/*.wit $$INSTALL_DIR/wit/ 2>/dev/null || true

# Help
help:
	@echo "wasm_shim Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build Erlang modules (default)"
	@echo "  erlang    - Build Erlang .beam files"
	@echo "  wasm      - Build WASM shim library"
	@echo "  nif       - Build NIF library"
	@echo "  examples  - Build examples"
	@echo "  test      - Run tests"
	@echo "  clean     - Remove build artifacts"
	@echo "  install   - Install to Erlang lib directory"
	@echo "  help      - Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  CC        - C compiler (default: gcc)"
	@echo "  ERLC      - Erlang compiler (default: erlc)"
	@echo "  WASM_CC   - WASM compiler (default: clang)"
