FROM prom/prometheus:v3.15.1

# entrypoint.sh renders prometheus.template.yml into prometheus.yml at startup
# (env substitution + "# @if FLAG" blocks), then execs Prometheus.
COPY ./prometheus.template.yml /etc/prometheus/prometheus.template.yml
COPY ./rules /etc/prometheus/rules
COPY --chmod=755 ./entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 9090
