ARG UPSTREAM_REPO
ARG UPSTREAM_TAG
FROM ${UPSTREAM_REPO:-uselagoon}/mariadb:${UPSTREAM_TAG:-latest}

ARG LAGOON_VERSION
ENV LAGOON_VERSION=$LAGOON_VERSION

ENV MARIADB_DATABASE=keycloak \
    MARIADB_USER=keycloak \
    MARIADB_PASSWORD=keycloak \
    MARIADB_CHARSET=utf8 \
    MARIADB_COLLATION=utf8_general_ci

# Setting mariadb config
USER root
COPY mariadb-client.cnf /etc/my.cnf.d/
RUN /bin/fix-permissions /etc/my.cnf.d/

USER mysql