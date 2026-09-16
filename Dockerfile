FROM alpine:3.24

RUN apk add --no-cache \
    bash coreutils findutils gawk grep sed shadow util-linux \
    curl openssl ca-certificates sudo tar gzip \
    lighttpd lighttpd-mod_auth apache2-utils fcgiwrap spawn-fcgi

RUN addgroup -S vmapi && adduser -S -D -H -h /var/lib/vmapi -s /sbin/nologin -G vmapi vmapi

COPY lib/common.sh /usr/local/lib/vmapi/common.sh
COPY bin/peerctl bin/vmbackupctl bin/metricsctl bin/logctl bin/certctl /usr/local/bin/
COPY cgi/api.cgi cgi/peer-api.cgi /usr/lib/vmapi/cgi/
COPY www/ /usr/share/vmapi/www/
COPY VERSION /usr/share/vmapi/VERSION
COPY docker/backup/vmapi.conf /etc/vmapi/vmapi.conf
COPY docker/backup/lighttpd.conf /etc/lighttpd/vmapi-container.conf
COPY docker/backup/entrypoint.sh /usr/local/bin/litevmm-backup-entrypoint

RUN chmod 0755 /usr/local/bin/peerctl /usr/local/bin/vmbackupctl /usr/local/bin/metricsctl /usr/local/bin/logctl /usr/local/bin/certctl \
    /usr/lib/vmapi/cgi/api.cgi /usr/lib/vmapi/cgi/peer-api.cgi /usr/local/bin/litevmm-backup-entrypoint \
 && mkdir -p /var/lib/vmapi/backups /var/lib/vmapi/peers /var/lib/vmapi/identity /run/vmapi /var/log/vmapi/backups \
 && chown -R vmapi:vmapi /var/lib/vmapi/backups /var/log/vmapi /run/vmapi

ENV VMAPI_HTTP_PORT=5186 \
    VMAPI_HTTP_USER=admin

VOLUME ["/var/lib/vmapi"]
EXPOSE 5186
ENTRYPOINT ["/usr/local/bin/litevmm-backup-entrypoint"]
