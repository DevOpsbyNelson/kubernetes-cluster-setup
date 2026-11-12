#!/bin/sh

set -eu

# Flags for the "# @if FLAG" ... "# @endif" blocks in the template (rule_files
# + scrape jobs). rabbitmq is opt-out, minio is opt-in. backoffice is opt-in:
# only RTM runs a backoffice, and an environment without a deployed one would
# otherwise fire BackofficeDown forever. Each rush-microservice is opt-in for
# the same reason, on its own flag: they deploy independently.
export SERVICE_ENABLED="${SERVICE_ENABLED:-true}"

# Render the template: drop "@if" blocks whose flag isn't "true" (their
# variables aren't required), then substitute ${VAR} placeholders, failing on
# any missing one.
awk '
/^[ \t]*# @if [A-Za-z_][A-Za-z0-9_]*[ \t]*$/ { skip = (ENVIRON[$3] != "true"); next }
/^[ \t]*# @endif[ \t]*$/ { skip = 0; next }
skip { next }
{
	line = $0
	while (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
		name = substr(line, RSTART + 2, RLENGTH - 3)
		if (!(name in ENVIRON)) {
			printf("Missing required environment variable: %s\n", name) > "/dev/stderr"
			exit 1
		}
		line = substr(line, 1, RSTART - 1) ENVIRON[name] substr(line, RSTART + RLENGTH)
	}
	print line
}
' /etc/prometheus/prometheus.template.yml > /etc/prometheus/prometheus.yml

# --web.enable-remote-write-receiver: Tempo's metrics_generator pushes its
# span-derived series (traces_service_graph_*, traces_spanmetrics_*) here over
# the private network; the public gateway blocks /api/v1/write (nginx.conf).
exec /bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --enable-feature=exemplar-storage \
  --web.enable-remote-write-receiver