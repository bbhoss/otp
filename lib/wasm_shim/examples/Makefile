#
# Makefile for wasm_shim examples
#

.PHONY: all clean wasm erlang

# Compilers
ERLC ?= erlc
WASM_CC ?= clang

# Directories
INCLUDE_DIR = ../include
SRC_DIR = ../src
EBIN_DIR = ../ebin

# WASM compilation flags
WASM_CFLAGS = -O2 -Wall -I$(INCLUDE_DIR) \
    --target=wasm32-wasi \
    -nostdlib \
    -Wl,--no-entry \
    -Wl,--export-dynamic

# Source files
WASM_SRCS = counter_server.c
ERL_SRCS = counter_example.erl

# Output files
WASM_BINS = $(WASM_SRCS:.c=.wasm)
ERL_BEAMS = $(ERL_SRCS:.erl=.beam)

# Default: build Erlang modules only (WASM requires clang with wasm target)
all: erlang

# Build WASM modules (requires clang with wasm32-wasi target)
wasm: $(WASM_BINS)

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
		echo "Warning: clang not found, skipping WASM compilation"; \
	fi

# Build Erlang modules
erlang: $(ERL_BEAMS)

%.beam: %.erl
	$(ERLC) -pa $(EBIN_DIR) -I $(INCLUDE_DIR) $<

# Clean
clean:
	rm -f $(WASM_BINS) $(ERL_BEAMS)

# Run the demo
demo: erlang
	@erl -pa . -pa $(EBIN_DIR) -noshell -eval 'counter_example:demo()' -s init stop

# Help
help:
	@echo "wasm_shim Examples Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all     - Build Erlang examples (default)"
	@echo "  erlang  - Build Erlang .beam files"
	@echo "  wasm    - Build WASM modules (requires clang with wasm32-wasi)"
	@echo "  demo    - Run the counter example demo"
	@echo "  clean   - Remove build artifacts"
