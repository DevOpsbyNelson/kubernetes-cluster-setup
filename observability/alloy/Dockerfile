FROM alpine AS setup

RUN apk add --no-cache busybox-static

FROM grafana/alloy:v1.21.2

COPY --from=setup /bin/busybox.static /bin/wget
COPY ./config.alloy /etc/alloy/config.alloy

EXPOSE 12345
EXPOSE 12347
EXPOSE 4317
EXPOSE 4318

CMD ["run", "/etc/alloy/config.alloy", "--server.http.listen-addr=0.0.0.0:12345"]