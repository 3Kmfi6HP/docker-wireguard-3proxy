# Use the latest Alpine Linux image as the base image
FROM alpine:latest

# Copy the entrypoint script to the container
COPY entrypoint.sh /usr/local/bin/

# Add the Alpine Linux edge/testing repository, install necessary packages, and set execute permissions for the entrypoint script
RUN echo "http://dl-4.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk add --no-cache \
    bash \
    curl \
    wget \
    wireguard-tools \
    openresolv \
    ip6tables \
    libgcc \
    libstdc++ \
    gnutls \
    expat \
    sqlite-libs \
    c-ares \
    openssl \
    3proxy && \
    chmod +x /usr/local/bin/entrypoint.sh

# Set environment variables for Wireguard options
ENV WIREGUARD_CONFIG                ""
ENV WIREGUARD_INTERFACE_PRIVATE_KEY ""
ENV WIREGUARD_INTERFACE_DNS         "1.1.1.1"
ENV WIREGUARD_INTERFACE_ADDRESS     ""
ENV WIREGUARD_PEER_PUBLIC_KEY       ""
ENV WIREGUARD_PEER_ALLOWED_IPS      "0.0.0.0/0"
ENV WIREGUARD_PEER_ENDPOINT         ""
ENV WIREGUARD_UP                    ""

# Set environment variables for Proxy options
ENV PROXY_USER                      ""
ENV PROXY_PASS                      ""
ENV PROXY_UP                        ""

# Set environment variables for Proxy Ports options
ENV SOCKS5_PROXY_PORT               "1080"
ENV HTTP_PROXY_PORT                 "3128"

# Set environment variable for Daemon mode
ENV DAEMON_MODE                     "false"

# Set the entrypoint script for the container
ENTRYPOINT [ "entrypoint.sh" ]
