# scraps publishes a statically linked musl build, so the runtime image carries
# the binary and nothing else. The wiki itself is not baked in — the git-sync
# sidecar clones it at runtime (see deployment.yaml).
FROM alpine:3.22 AS fetch
ARG SCRAPS_VERSION
RUN apk add --no-cache curl \
 && curl -fsSL "https://github.com/boykush/scraps/releases/download/${SCRAPS_VERSION}/scraps-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C /usr/local/bin \
 && chmod +x /usr/local/bin/scraps \
 && /usr/local/bin/scraps --version

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=fetch /usr/local/bin/scraps /usr/local/bin/scraps
EXPOSE 1113
ENTRYPOINT ["/usr/local/bin/scraps"]
