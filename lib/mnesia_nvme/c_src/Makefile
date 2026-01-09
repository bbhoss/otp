# Makefile for mnesia_nvme NIF
#
# This builds the NIF shared library for NVMe KV operations.
# Requires: liburing-dev (for io_uring support)

UNAME_S := $(shell uname -s)

# Erlang paths
ERL_INCLUDE := $(shell erl -noshell -eval 'io:format("~s", [code:lib_dir(erts, include)])' -s init stop)
EI_INCLUDE := $(shell erl -noshell -eval 'io:format("~s", [code:lib_dir(erl_interface, include)])' -s init stop)

# Compiler settings
CC := gcc
CFLAGS := -O2 -fPIC -Wall -Wextra -I$(ERL_INCLUDE) -I$(EI_INCLUDE)
LDFLAGS := -shared

# Linux-specific: check for liburing
ifeq ($(UNAME_S),Linux)
    # Check if liburing is available
    LIBURING_EXISTS := $(shell pkg-config --exists liburing 2>/dev/null && echo yes || echo no)
    ifeq ($(LIBURING_EXISTS),yes)
        CFLAGS += $(shell pkg-config --cflags liburing) -DHAVE_IO_URING_CMD
        LDFLAGS += $(shell pkg-config --libs liburing)
    else
        # Try default paths
        ifneq ($(wildcard /usr/include/liburing.h),)
            CFLAGS += -DHAVE_IO_URING_CMD
            LDFLAGS += -luring
        endif
    endif
endif

# Output
PRIV_DIR := ../priv
TARGET := $(PRIV_DIR)/mnesia_nvme_nif.so

# Source files
SRCS := mnesia_nvme_nif.c
OBJS := $(SRCS:.c=.o)

.PHONY: all clean priv_dir

all: priv_dir $(TARGET)

priv_dir:
	@mkdir -p $(PRIV_DIR)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

# Print configuration for debugging
info:
	@echo "ERL_INCLUDE: $(ERL_INCLUDE)"
	@echo "EI_INCLUDE: $(EI_INCLUDE)"
	@echo "CFLAGS: $(CFLAGS)"
	@echo "LDFLAGS: $(LDFLAGS)"
	@echo "LIBURING_EXISTS: $(LIBURING_EXISTS)"
