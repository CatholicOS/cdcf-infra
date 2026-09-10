FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        coreutils \
        curl \
        diffutils \
        gettext-base \
        nginx \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

COPY entrypoint.sh /usr/local/bin/nginx-simulation-entrypoint
RUN chmod 0755 /usr/local/bin/nginx-simulation-entrypoint

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/nginx-simulation-entrypoint"]
