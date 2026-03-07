#!/bin/bash

# QUIC interop runner endpoint script
# Invoked by quic-interop-runner for both client and server roles

set -e

# Setup routing for the network simulator
if [ -f /setup.sh ]; then
    source /setup.sh
fi

echo "OTP QUIC interop endpoint"
echo "ROLE=$ROLE"
echo "TESTCASE=$TESTCASE"

ERL="/otp/bin/erl"
PA="/otp/lib/quic/ebin"
INTEROP="/otp/lib/quic/interop"

if [ "$ROLE" = "client" ]; then
    # Wait for the simulator to be ready
    echo "Waiting for simulator..."
    timeout 30 bash -c 'until nc -z sim 57832 2>/dev/null; do sleep 0.2; done' || true
    echo "Starting client..."

    $ERL -pa $PA -noinput -eval "
        c:c(\"$INTEROP/quic_interop_client\"),
        quic_interop_client:main(string:tokens(\"$REQUESTS\", \" \")).
    "
else
    echo "Starting server..."

    $ERL -pa $PA -noinput -eval "
        c:c(\"$INTEROP/quic_interop_server\"),
        quic_interop_server:main([]).
    "
fi
