FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        postgresql-16 \
        postgresql-client-16 \
        ca-certificates \
    && pg_dropcluster --stop 16 main \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/sbin/postgres-host-entrypoint.sh

RUN chmod 0755 /usr/local/sbin/postgres-host-entrypoint.sh

EXPOSE 5432

ENTRYPOINT ["/usr/local/sbin/postgres-host-entrypoint.sh"]
