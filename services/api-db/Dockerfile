ARG UPSTREAM_REPO
ARG UPSTREAM_TAG
FROM ${UPSTREAM_REPO:-uselagoon}/mariadb:${UPSTREAM_TAG:-latest}

ARG LAGOON_VERSION
ENV LAGOON_VERSION=$LAGOON_VERSION

USER root
RUN apk add --no-cache openssh-keygen
USER mysql

ENV MARIADB_DATABASE=infrastructure \
    MARIADB_USER=api \
    MARIADB_PASSWORD=api \
    MARIADB_CHARSET=utf8 \
    MARIADB_COLLATION=utf8_general_ci

# Setting mariadb config
USER root
COPY mariadb-client.cnf /etc/my.cnf.d/
RUN /bin/fix-permissions /etc/my.cnf.d/

USER mysql
COPY ./docker-entrypoint-initdb.d/* /docker-entrypoint-initdb.d/
RUN chown -R mysql /docker-entrypoint-initdb.d/; /bin/fix-permissions /docker-entrypoint-initdb.d/
COPY ./rerun_initdb.sh /rerun_initdb.sh
