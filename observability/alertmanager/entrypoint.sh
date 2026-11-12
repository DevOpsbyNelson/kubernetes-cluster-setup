#!/bin/sh
 
set -eu

awk '
{
	line = $0

	while (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
		variable_name = substr(line, RSTART + 2, RLENGTH - 3)

		if (!(variable_name in ENVIRON)) {
			printf("Missing required environment variable: %s\n", variable_name) > "/dev/stderr"
			exit 1
		}

		line = substr(line, 1, RSTART - 1) ENVIRON[variable_name] substr(line, RSTART + RLENGTH)
	}

	print line
}
' /etc/alertmanager/alertmanager.template.yml > /etc/alertmanager/alertmanager.yml

exec /bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/alertmanager