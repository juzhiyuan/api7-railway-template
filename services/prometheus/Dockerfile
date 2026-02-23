FROM docker.io/api7/prometheus:2.48.1-debian-11-r0

EXPOSE 9090

CMD ["--config.file=/opt/bitnami/prometheus/conf/prometheus.yml", "--web.enable-remote-write-receiver"]
