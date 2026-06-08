# Browser-test container: vanilla openwrt/rootfs with LuCI + rpcd + sing-box.
# Built once per Dockerfile/entrypoint/uhttpd.conf hash, cached by buildx.
#
# Package set was empirically narrowed in the T1 spike: openssl/mkpasswd/
# chpasswd are NOT needed (entrypoint.sh seeds the root password via
# busybox's `passwd` + stdin). The package list below is the minimum that
# produces a LuCI that renders without HTTP 500.
FROM openwrt/rootfs:x86_64-25.12.3

RUN apk update \
 && apk add luci uhttpd rpcd sing-box ucode-mod-fs ucode-mod-uci \
 && rm -rf /var/cache/apk/*

COPY uhttpd.conf  /etc/config/uhttpd
COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod +x /sbin/entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/sbin/entrypoint.sh"]
