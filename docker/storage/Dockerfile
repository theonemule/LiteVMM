FROM gogost/gost:3.2.6 AS gost

FROM alpine:3.24 AS unfs3-build

ARG UNFS3_VERSION=0.11.0
ARG UNFS3_SHA256=563359f4e336d89f3f04361555ff4483acb951b1442a067407a19214410668c6

RUN apk add --no-cache     ca-certificates curl build-base autoconf automake flex bison     libtirpc-dev linux-headers

WORKDIR /src
RUN curl -fsSL "https://github.com/unfs3/unfs3/archive/refs/tags/unfs3-${UNFS3_VERSION}.tar.gz" -o unfs3.tar.gz  && printf '%s  %s\n' "$UNFS3_SHA256" unfs3.tar.gz | sha256sum -c -  && tar -xzf unfs3.tar.gz --strip-components=1  && ./bootstrap  && ./configure --prefix=/usr/local  && make -j"$(nproc)"  && make install DESTDIR=/out

FROM alpine:3.24

ARG LITEVMM_VERSION=dev

LABEL org.opencontainers.image.title="LiteVMM Storage"       org.opencontainers.image.description="Containerized LiteVMM backup and peer-storage node"       org.opencontainers.image.version="${LITEVMM_VERSION}"       org.opencontainers.image.source="https://github.com/theonemule/LiteVMM"       org.opencontainers.image.url="https://github.com/theonemule/LiteVMM"       org.opencontainers.image.documentation="https://github.com/theonemule/LiteVMM#containerized-backup-storage-node"

RUN apk add --no-cache     bash coreutils findutils gawk grep sed shadow util-linux     curl jq openssl ca-certificates sudo tar gzip zip iproute2     lighttpd lighttpd-mod_auth apache2-utils fcgiwrap spawn-fcgi ttyd certbot     nfs-utils libtirpc

COPY --from=gost /bin/gost /usr/local/bin/gost
COPY --from=unfs3-build /out/usr/local/sbin/unfsd /usr/local/sbin/unfsd

RUN addgroup -S vmapi  && adduser -S -D -H -h /var/lib/vmapi -s /sbin/nologin -G vmapi vmapi

COPY lib/common.sh /usr/local/lib/vmapi/common.sh
COPY bin/vmapi bin/vmapi-web-reload bin/hostexecctl bin/filectl bin/peerctl bin/vmbackupctl bin/replicationctl bin/peer-volumectl bin/backplanectl bin/metricsctl bin/logctl bin/certctl /usr/local/bin/
COPY cgi/api.cgi cgi/peer-api.cgi /usr/lib/vmapi/cgi/
COPY www/ /usr/share/vmapi/www/
COPY VERSION /usr/share/vmapi/VERSION
COPY docker/storage/vmapi.conf /usr/share/vmapi/vmapi-container-defaults.conf
COPY docker/backup/lighttpd.conf /etc/lighttpd/vmapi-container.conf
COPY docker/backup/entrypoint.sh /usr/local/bin/litevmm-backup-entrypoint

RUN chmod 0755       /usr/local/bin/vmapi       /usr/local/bin/vmapi-web-reload       /usr/local/bin/hostexecctl       /usr/local/bin/filectl       /usr/local/bin/peerctl       /usr/local/bin/vmbackupctl       /usr/local/bin/replicationctl       /usr/local/bin/peer-volumectl       /usr/local/bin/backplanectl       /usr/local/bin/metricsctl       /usr/local/bin/logctl       /usr/local/bin/certctl       /usr/local/sbin/unfsd       /usr/lib/vmapi/cgi/api.cgi       /usr/lib/vmapi/cgi/peer-api.cgi       /usr/local/bin/litevmm-backup-entrypoint  && mkdir -p       /var/lib/vmapi/backups       /var/lib/vmapi/backplane/peers       /var/lib/vmapi/backplane/shared/isos       /var/lib/vmapi/peers       /var/lib/vmapi/identity       /var/lib/vmapi/backup-jobs       /run/vmapi       /run/vmapi-backplane       /var/log/vmapi/backups  && chmod 0770 /var/lib/vmapi/backplane/peers  && chown -R vmapi:vmapi       /var/lib/vmapi/backups       /var/lib/vmapi/backup-jobs       /var/log/vmapi       /run/vmapi

ENV VMAPI_HTTP_PORT=5186     VMAPI_HTTP_USER=admin

VOLUME ["/var/lib/vmapi"]
EXPOSE 5186

ENTRYPOINT ["/usr/local/bin/litevmm-backup-entrypoint"]
