FROM rust:1.99-bookworm AS builder
WORKDIR /src
# Build from the repository root so the yl-proto path dependency is present.
COPY . /src
WORKDIR /src/server
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /data --shell /usr/sbin/nologin yuanlian
COPY --from=builder /src/server/target/release/yl-server /usr/local/bin/yl-server
RUN mkdir -p /data && chown yuanlian:yuanlian /data
USER yuanlian
ENV YUANLIAN_BIND=0.0.0.0:18080 \
    YUANLIAN_DB=/data/yuanlian.db \
    RUST_LOG=yl_server=info,info
VOLUME ["/data"]
EXPOSE 18080
HEALTHCHECK --interval=30s --timeout=3s CMD curl --fail --silent http://127.0.0.1:18080/health || exit 1
ENTRYPOINT ["/usr/local/bin/yl-server"]
