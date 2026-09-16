FROM alpine:3.24

RUN apk add --no-cache \
    bash coreutils findutils gawk grep sed shadow util-linux \
    curl openssl ca-certificates sudo tar gzip iproute2 qemu-img \
    lighttpd lighttpd-mod_auth apache2-utils fcgiwrap spawn-fcgi


ARG TARGETARCH
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) gost_sha=b39037b0380ea001fb3c0c28441c2e10bfc694f90682739a65b53e55dce5238b ;; \
      arm64) gost_sha=f674c8f4a033dc1dfd4f0d5e9602fbe5b0d0f81307bf3794f44b5b5d6d622eae ;; \
      *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    asset="gost_3.2.6_linux_${TARGETARCH}.tar.gz"; \
    curl --fail --location --proto '=https' --tlsv1.2 -o "/tmp/$asset" "https://github.com/go-gost/gost/releases/download/v3.2.6/$asset"; \
    echo "$gost_sha  /tmp/$asset" | sha256sum -c -; \
    tar -xzf "/tmp/$asset" -C /tmp; \
    install -m 0755 "$(find /tmp -type f -name gost -print -quit)" /usr/local/bin/gost; \
    rm -f "/tmp/$asset" /tmp/gost

RUN addgroup -S vmapi && adduser -S -D -H -h /var/lib/vmapi -s /sbin/nologin -G vmapi vmapi

COPY lib/common.sh /usr/local/lib/vmapi/common.sh
COPY bin/peerctl bin/vmbackupctl bin/replicationctl bin/metricsctl bin/logctl bin/certctl /usr/local/bin/
COPY cgi/api.cgi cgi/peer-api.cgi /usr/lib/vmapi/cgi/
COPY www/ /usr/share/vmapi/www/
COPY VERSION /usr/share/vmapi/VERSION
COPY docker/backup/vmapi.conf /etc/vmapi/vmapi.conf
COPY docker/backup/lighttpd.conf /etc/lighttpd/vmapi-container.conf
COPY docker/backup/entrypoint.sh /usr/local/bin/litevmm-backup-entrypoint

RUN chmod 0755 /usr/local/bin/peerctl /usr/local/bin/vmbackupctl /usr/local/bin/replicationctl /usr/local/bin/metricsctl /usr/local/bin/logctl /usr/local/bin/certctl \
    /usr/lib/vmapi/cgi/api.cgi /usr/lib/vmapi/cgi/peer-api.cgi /usr/local/bin/litevmm-backup-entrypoint \
 && mkdir -p /var/lib/vmapi/backups /var/lib/vmapi/replicas /var/lib/vmapi/replication-jobs /var/lib/vmapi/replication-receivers /var/lib/vmapi/peers /var/lib/vmapi/identity /run/vmapi /var/log/vmapi/backups \
 && chown -R vmapi:vmapi /var/lib/vmapi/backups /var/log/vmapi /run/vmapi

ENV VMAPI_HTTP_PORT=5186 \
    VMAPI_HTTP_USER=admin

VOLUME ["/var/lib/vmapi"]
EXPOSE 5186
ENTRYPOINT ["/usr/local/bin/litevmm-backup-entrypoint"]
