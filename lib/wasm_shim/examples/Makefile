#
# Makefile for wasm_shim examples
#

.PHONY: all clean wasm wasm-c wasm-rust erlang rust-demo c-demo

# Compilers
ERLC ?= erlc
WASM_CC ?= clang
CARGO ?= cargo

# Directories
INCLUDE_DIR = ../include
SRC_DIR = ../src
EBIN_DIR = ../ebin
RUST_DIR = rust_counter

# WASM compilation flags for C
WASM_CFLAGS = -O2 -Wall -I$(INCLUDE_DIR) \
    --target=wasm32-wasi \
    -nostdlib \
    -Wl,--no-entry \
    -Wl,--export-dynamic

# Rust WASM target
RUST_TARGET ?= wasm32-unknown-unknown

# Source files
C_WASM_SRCS = counter_server.c
ERL_SRCS = counter_example.erl rust_counter_example.erl

# Output files
C_WASM_BINS = $(C_WASM_SRCS:.c=.wasm)
RUST_WASM_BIN = $(RUST_DIR)/target/$(RUST_TARGET)/release/rust_counter.wasm
ERL_BEAMS = $(ERL_SRCS:.erl=.beam)

# Default: build Erlang modules only
all: erlang

# Build all WASM modules
wasm: wasm-c wasm-rust

# Build C WASM modules (requires clang with wasm32-wasi target)
wasm-c: $(C_WASM_BINS)

%.wasm: %.c
	@if command -v $(WASM_CC) >/dev/null 2>&1; then \
		if $(WASM_CC) --print-targets 2>/dev/null | grep -q wasm32; then \
			echo "Compiling $< to WASM..."; \
			$(WASM_CC) $(WASM_CFLAGS) $< $(SRC_DIR)/erl_wasm_shim.c -o $@; \
		else \
			echo "Warning: clang does not have wasm32 target support"; \
			echo "Skipping WASM compilation for $<"; \
		fi; \
	else \
		echo "Warning: clang not found, skipping C WASM compilation"; \
	fi

# Build Rust WASM module
wasm-rust:
	@if command -v $(CARGO) >/dev/null 2>&1; then \
		echo "Building Rust counter server..."; \
		cd $(RUST_DIR) && $(CARGO) build --release --target $(RUST_TARGET); \
		if [ -f "target/$(RUST_TARGET)/release/rust_counter.wasm" ]; then \
			cp target/$(RUST_TARGET)/release/rust_counter.wasm ../rust_counter.wasm; \
			echo "Rust WASM built: rust_counter.wasm"; \
		fi; \
	else \
		echo "Warning: cargo not found, skipping Rust WASM compilation"; \
		echo "  Install Rust from https://rustup.rs/"; \
		echo "  Then: rustup target add $(RUST_TARGET)"; \
	fi

# Build Erlang modules
erlang: $(ERL_BEAMS)

%.beam: %.erl
	$(ERLC) -pa $(EBIN_DIR) -I $(INCLUDE_DIR) $<

# Clean
clean:
	rm -f $(C_WASM_BINS) $(ERL_BEAMS) rust_counter.wasm
	@if [ -d $(RUST_DIR) ]; then \
		cd $(RUST_DIR) && $(CARGO) clean 2>/dev/null || true; \
	fi

# Run the C counter demo
c-demo: erlang
	@erl -pa . -pa $(EBIN_DIR) -noshell -eval 'counter_example:demo()' -s init stop

# Run the Rust counter demo
rust-demo: erlang
	@erl -pa . -pa $(EBIN_DIR) -noshell -eval 'rust_counter_example:demo()' -s init stop

# Run both demos
demo: erlang
	@echo "=== C Counter Demo ==="
	@erl -pa . -pa $(EBIN_DIR) -noshell -eval 'counter_example:demo()' -s init stop
	@echo ""
	@echo "=== Rust Counter Demo ==="
	@erl -pa . -pa $(EBIN_DIR) -noshell -eval 'rust_counter_example:demo()' -s init stop

# Help
help:
	@echo "wasm_shim Examples Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Build Erlang examples (default)"
	@echo "  erlang     - Build Erlang .beam files"
	@echo "  wasm       - Build all WASM modules (C and Rust)"
	@echo "  wasm-c     - Build C WASM module (requires clang with wasm32-wasi)"
	@echo "  wasm-rust  - Build Rust WASM module (requires cargo)"
	@echo "  c-demo     - Run the C counter example demo"
	@echo "  rust-demo  - Run the Rust counter example demo"
	@echo "  demo       - Run both demos"
	@echo "  clean      - Remove build artifacts"
	@echo ""
	@echo "Prerequisites for WASM compilation:"
	@echo "  C:    clang with wasm32-wasi target"
	@echo "  Rust: cargo + rustup target add wasm32-unknown-unknown"
