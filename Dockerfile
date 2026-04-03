# ==========================================
# Stage 1: Build
# ==========================================
FROM docker.io/library/golang:1.26-alpine AS builder

# Install make and git (Alpine doesn't include make by default, and git is often needed for go mod tidy)
RUN apk add --no-cache make git

# Copy the entire repository into the build context
WORKDIR /src
COPY . .

# 1. Build Arnika (Following README: cd arnika -> go mod tidy -> make build)
# We are already in /src (which is the arnika root)
RUN go mod tidy && \
    make build && \
    mkdir -p /app && \
    mv build/arnika /app/arnika

# 2. Build KMS Simulator (Following README: cd arnika/tools -> go mod tidy -> go build -o kms)
WORKDIR /src/tools
RUN go mod tidy && \
    go build -o /app/kms

# 3. Create the entrypoint script
RUN echo '#!/bin/sh' > /app/entrypoint.sh && \
    echo 'if [ "$WITH_KMS" = "true" ] || [ "$WITH_KMS" = "1" ]; then' >> /app/entrypoint.sh && \
    echo '  echo "Starting KMS Simulator in the background..."' >> /app/entrypoint.sh && \
    echo '  /app/kms &' >> /app/entrypoint.sh && \
    echo '  sleep 2' >> /app/entrypoint.sh && \
    echo 'fi' >> /app/entrypoint.sh && \
    echo 'echo "Starting Arnika..."' >> /app/entrypoint.sh && \
    echo 'exec /app/arnika "$@"' >> /app/entrypoint.sh && \
    chmod +x /app/entrypoint.sh

# ==========================================
# Stage 2: Production
# ==========================================
FROM docker.io/alpine:latest

# Install minimal runtime dependencies (certificates are often needed for KMS HTTPS calls)
RUN apk add --no-cache ca-certificates \
    tzdata \
    bash \
    wireguard-tools \
    iproute2 \
    iputils \
    curl \
    jq

# Create the low privileged app user with UID 10001
RUN addgroup -g 10001 appgroup && \
    adduser -D -u 10001 -G appgroup -h /app appuser

# Set working directory to the user's home
WORKDIR /app

# Copy the compiled binaries and entrypoint from the builder stage
# Chown them directly during the copy to minimize image layers
COPY --from=builder --chown=appuser:appgroup /app/arnika /app/arnika
COPY --from=builder --chown=appuser:appgroup /app/kms /app/kms
COPY --from=builder --chown=appuser:appgroup /app/entrypoint.sh /app/entrypoint.sh

# Switch to the non-root user (using UID:GID)
USER 10001:10001

# Environment variable to control the KMS simulator (defaults to false)
ENV WITH_KMS=false

# Expose relevant ports if known (e.g., Arnika might listen on 8080/9999, KMS on 7000)
# EXPOSE 8080 7000

# Launch via the entrypoint script
ENTRYPOINT ["/app/entrypoint.sh"]