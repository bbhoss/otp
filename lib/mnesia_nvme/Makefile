# Top-level Makefile for mnesia_nvme
#
# This builds both the Erlang application and the NIF.

.PHONY: all compile nif clean test erlang

all: compile

compile: ebin erlang
	@echo "Attempting to build NIF (optional)..."
	-$(MAKE) -C c_src 2>/dev/null || echo "NIF build skipped (liburing not available or compile error)"

erlang: ebin
	@echo "Compiling Erlang sources..."
	erlc -o ebin -I include src/*.erl

nif:
	@echo "Building NIF..."
	$(MAKE) -C c_src

ebin:
	mkdir -p ebin

clean:
	$(MAKE) -C c_src clean
	rm -rf ebin/*.beam _build

test:
	ct_run -pa ebin -dir test

# Development helpers
shell: compile
	erl -pa ebin -eval "application:start(mnesia_nvme)"

dialyzer:
	dialyzer --src src -I include
