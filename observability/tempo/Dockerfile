FROM grafana/tempo:3.1.1

COPY ./tempo.yaml /etc/tempo.yaml

# -config.expand-env substitutes the ${VAR} / ${VAR:-default} placeholders in
# tempo.yaml (the Prometheus remote-write URL).
CMD ["-target=all", "-config.file=/etc/tempo.yaml", "-config.expand-env=true"]

# HTTP API (queried by Grafana), OTLP gRPC, OTLP HTTP
EXPOSE 3200 4317 4318
