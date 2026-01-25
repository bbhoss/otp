# MQuickJS Erlang Integration Makefile
#
# Copyright Ericsson AB 2025. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0

# Paths - use OTP source tree paths
OTP_ROOT = /home/user/otp
MQUICKJS_DIR = /home/user/mquickjs
ERL_INTERFACE_DIR = $(OTP_ROOT)/lib/erl_interface

# Compiler settings
CC = gcc
CFLAGS = -Wall -g -O2 -fPIC -D_GNU_SOURCE -D_REENTRANT -fno-math-errno -fno-trapping-math
LDFLAGS = -g

# Include paths
INCLUDES = -I$(MQUICKJS_DIR) \
           -I$(ERL_INTERFACE_DIR)/include

# For linking, we need the built ei library
# Use the built library location
EI_LIB_DIR = $(ERL_INTERFACE_DIR)/obj/x86_64-pc-linux-gnu

# Library paths
LIBS = -L$(EI_LIB_DIR) -lei -lpthread -lm

# Erlang compiler - try to find it
ERLC = $(shell which erlc 2>/dev/null || echo $(OTP_ROOT)/bin/erlc)
ERLCFLAGS = -W +debug_info

# Directories
C_SRC_DIR = c_src
SRC_DIR = src
EBIN_DIR = ebin
PRIV_DIR = priv

# Source files
CNODE_SRCS = $(C_SRC_DIR)/mquickjs_cnode.c
MQUICKJS_SRCS = $(MQUICKJS_DIR)/mquickjs.c \
                $(MQUICKJS_DIR)/dtoa.c \
                $(MQUICKJS_DIR)/libm.c \
                $(MQUICKJS_DIR)/cutils.c

ERL_SRCS = $(wildcard $(SRC_DIR)/*.erl)
ERL_BEAMS = $(patsubst $(SRC_DIR)/%.erl,$(EBIN_DIR)/%.beam,$(ERL_SRCS))

# Targets
CNODE_TARGET = $(PRIV_DIR)/mquickjs_cnode

.PHONY: all clean mquickjs_lib erlang cnode

all: dirs mquickjs_lib cnode erlang

dirs:
	@mkdir -p $(EBIN_DIR) $(PRIV_DIR)

# Build mquickjs library files (generates example_stdlib.h)
mquickjs_lib:
	@echo "Building mquickjs library..."
	$(MAKE) -C $(MQUICKJS_DIR)

# Build C node
cnode: $(CNODE_TARGET)

$(CNODE_TARGET): $(CNODE_SRCS) mquickjs_lib
	@echo "Building C node..."
	@echo "Looking for ei library in: $(EI_LIB_DIR)"
	$(CC) $(CFLAGS) $(INCLUDES) \
		-o $@ \
		$(CNODE_SRCS) \
		$(MQUICKJS_SRCS) \
		$(LIBS)

# Build Erlang modules (skip if erlc not available)
erlang: $(ERL_BEAMS)

$(EBIN_DIR)/%.beam: $(SRC_DIR)/%.erl
	@if [ -x "$(ERLC)" ]; then \
		$(ERLC) $(ERLCFLAGS) -o $(EBIN_DIR) $<; \
	else \
		echo "Warning: erlc not found, skipping Erlang compilation"; \
	fi

clean:
	rm -f $(EBIN_DIR)/*.beam
	rm -f $(PRIV_DIR)/mquickjs_cnode
	rm -f $(C_SRC_DIR)/*.o

distclean: clean
	$(MAKE) -C $(MQUICKJS_DIR) clean
