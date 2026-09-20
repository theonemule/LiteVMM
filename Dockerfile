FROM gogost/gost:3.2.6 AS gost

FROM alpine:3.24

RUN apk add --no-cache \
    bash coreutils findutils gawk grep sed shadow util-linux \
    curl jq openssl ca-certificates sudo tar gzip iproute2 \
    lighttpd lighttpd-mod_auth apache2-utils fcgiwrap spawn-fcgi certbot \
    nfs-utils

COPY --from=gost /bin/gost /usr/local/bin/gost

RUN addgroup -S vmapi && adduser -S -D -H -h /var/lib/vmapi -s /sbin/nologin -G vmapi vmapi

COPY lib/common.sh /usr/local/lib/vmapi/common.sh
COPY bin/vmapi bin/peerctl bin/vmbackupctl bin/replicationctl bin/peer-volumectl bin/backplanectl bin/metricsctl bin/logctl bin/certctl /usr/local/bin/
COPY cgi/api.cgi cgi/peer-api.cgi /usr/lib/vmapi/cgi/
COPY www/ /usr/share/vmapi/www/
COPY VERSION /usr/share/vmapi/VERSION
COPY docker/backup/vmapi.conf /etc/vmapi/vmapi.conf
COPY docker/backup/lighttpd.conf /etc/lighttpd/vmapi-container.conf
COPY docker/backup/entrypoint.sh /usr/local/bin/litevmm-backup-entrypoint

RUN chmod 0755 /usr/local/bin/vmapi /usr/local/bin/peerctl /usr/local/bin/vmbackupctl /usr/local/bin/replicationctl /usr/local/bin/peer-volumectl /usr/local/bin/backplanectl /usr/local/bin/metricsctl /usr/local/bin/logctl /usr/local/bin/certctl \
    /usr/lib/vmapi/cgi/api.cgi /usr/lib/vmapi/cgi/peer-api.cgi /usr/local/bin/litevmm-backup-entrypoint \
 && mkdir -p /var/lib/vmapi/backups /var/lib/vmapi/backplane/peers /var/lib/vmapi/peers /var/lib/vmapi/identity /var/lib/vmapi/backup-jobs /run/vmapi /run/vmapi-backplane /var/log/vmapi/backups \
 && chmod 0770 /var/lib/vmapi/backplane/peers \
 && chown -R vmapi:vmapi /var/lib/vmapi/backups /var/lib/vmapi/backup-jobs /var/log/vmapi /run/vmapi

ENV VMAPI_HTTP_PORT=5186 \
    VMAPI_HTTP_USER=admin

VOLUME ["/var/lib/vmapi"]
EXPOSE 5186
ENTRYPOINT ["/usr/local/bin/litevmm-backup-entrypoint"]
