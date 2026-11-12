FROM prom/alertmanager:v0.34.1

USER root

COPY alertmanager.template.yml /etc/alertmanager/alertmanager.template.yml
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

USER nobody

EXPOSE 9093 

ENTRYPOINT ["/entrypoint.sh"]