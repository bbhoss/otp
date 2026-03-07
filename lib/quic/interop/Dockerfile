FROM martenseemann/quic-network-simulator-endpoint:latest AS builder

RUN apt-get update && apt-get install -y \
    build-essential \
    autoconf \
    libncurses5-dev \
    libssl-dev \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

COPY . /otp
WORKDIR /otp

# Build OTP with QUIC support
ENV ERL_TOP=/otp
RUN ./configure && make -j$(nproc)

FROM martenseemann/quic-network-simulator-endpoint:latest

RUN apt-get update && apt-get install -y \
    libncurses5 \
    libssl3 \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Copy the built OTP
COPY --from=builder /otp /otp

# Copy interop scripts
COPY lib/quic/interop/run_endpoint.sh /run_endpoint.sh
RUN chmod +x /run_endpoint.sh

ENV PATH="/otp/bin:${PATH}"

ENTRYPOINT ["/run_endpoint.sh"]
