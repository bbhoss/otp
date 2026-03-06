# QUIC Development Guide

## Building OTP

```bash
cd /home/user/otp
export ERL_TOP=/home/user/otp
./configure        # only needed once
make -j$(nproc)    # full build
```

To rebuild just the QUIC library after changes:
```bash
ERL_TOP=/home/user/otp make -C lib/quic
```

## Running the Chat Server

```bash
cd /home/user/otp/lib/quic/examples
/home/user/otp/bin/erl -pa /home/user/otp/lib/quic/ebin -noinput -eval '
  c:c(quic_chat_server),
  {ok, _} = quic_chat_server:start(4433,
    "/home/user/otp/lib/quic/examples/cert.pem",
    "/home/user/otp/lib/quic/examples/key.pem"),
  timer:sleep(infinity).
' > /tmp/chat_server.log 2>&1 &
```

Check it started: `cat /tmp/chat_server.log` should show `[chat] Listening on port 4433`.

Kill: `pkill -f "beam.*quic"`

## Building and Running Stress Tests

Build (one-time):
```bash
cd /home/user/otp/lib/quic/examples/go_chat_client
go build -o /tmp/stresstest ./cmd/stresstest/
```

Run scenarios (server must be running on port 4433):
```bash
# Quick smoke test - multistream (single connection, fast)
/tmp/stresstest -scenario multistream -addr localhost:4433 -streams 5

# Flood test (message throughput)
/tmp/stresstest -scenario flood -addr localhost:4433 -flood-msgs 100

# Multi-client stampede (keep clients low, handshakes are slow)
/tmp/stresstest -scenario stampede -addr localhost:4433 -clients 2 -msgs 5

# Churn (connect/disconnect cycles)
/tmp/stresstest -scenario churn -addr localhost:4433 -rounds 5

# Rude disconnects (abrupt close, error paths)
/tmp/stresstest -scenario rude -addr localhost:4433 -rude-count 10
```

Note: stampede with >2 clients is slow due to pure-Erlang TLS handshakes.
The multistream and flood scenarios are fast and best for quick verification.

## Running Erlang Tests

```bash
cd /home/user/otp
# Not yet working via standard ct_run — tests use modules directly
```

## Key Paths

- QUIC source: `lib/quic/src/`
- QUIC headers: `lib/quic/src/quic.hrl`
- QUIC tests: `lib/quic/test/`
- Chat server: `lib/quic/examples/quic_chat_server.erl`
- Go client: `lib/quic/examples/go_chat_client/`
- Stress test: `lib/quic/examples/go_chat_client/cmd/stresstest/`
- Certs: `lib/quic/examples/cert.pem`, `key.pem`
- RFCs: `rfc/rfc9000.txt` (transport), `rfc9001.txt` (TLS), `rfc9002.txt` (recovery), `rfc8999.txt` (invariants)

## Verification Workflow

After making changes:
1. `ERL_TOP=/home/user/otp make -C lib/quic` — compile
2. Start chat server (see above)
3. `/tmp/stresstest -scenario multistream -addr localhost:4433 -streams 5` — quick smoke
4. `/tmp/stresstest -scenario flood -addr localhost:4433 -flood-msgs 100` — throughput
5. `/tmp/stresstest -scenario stampede -addr localhost:4433 -clients 2 -msgs 5` — multi-client
6. Kill server when done
