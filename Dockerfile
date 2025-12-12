FROM alpine AS builder

FROM scratch
COPY --from=builder /etc/ssl/certs/ /etc/ssl/certs/
COPY zig-out/bin/ddns-ns1  /ddns-ns1
ENTRYPOINT ["/ddns-ns1"]