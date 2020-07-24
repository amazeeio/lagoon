ARG ALPINE_VERSION
ARG IMAGE_REPO
FROM ${IMAGE_REPO:-lagoon}/commons as commons
FROM alpine:${ALPINE_VERSION}

LABEL maintainer="amazee.io"

ARG LAGOON_VERSION
ENV LAGOON_VERSION=$LAGOON_VERSION

# Copy commons files
COPY --from=commons /lagoon /lagoon
COPY --from=commons /bin/fix-permissions /bin/ep /bin/docker-sleep /bin/
COPY --from=commons /sbin/tini /sbin/
COPY --from=commons /home /home

RUN chmod g+w /etc/passwd \
    && mkdir -p /home

ENV TMPDIR=/tmp \
    TMP=/tmp \
    HOME=/home \
    # When Bash is invoked via `sh` it behaves like the old Bourne Shell and sources a file that is given in `ENV`
    ENV=/home/.bashrc \
    # When Bash is invoked as non-interactive (like `bash -c command`) it sources a file that is given in `BASH_ENV`
    BASH_ENV=/home/.bashrc

ENV BACKUPS_DIR="/var/lib/mysql/backup"

ENV MARIADB_DATABASE=lagoon \
    MARIADB_USER=lagoon \
    MARIADB_PASSWORD=lagoon \
    MARIADB_ROOT_PASSWORD=Lag00n

ENV MARIADB_READONLY_USER=lagoon_readonly \
    MARIADB_READONLY_PASSWORD=lag00n_readonly

RUN \
    apk add --no-cache --virtual .common-run-deps \
    bash \
    curl \
    mariadb \
    mariadb-client \
    mariadb-common \
    mariadb-server-utils \
    net-tools \
    pwgen \
    tzdata \
    wget \
    gettext; \
    rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*; \
    rm -rf /var/lib/mysql/* /etc/mysql/ /etc/my.cnf*; \
    curl -sSL http://mysqltuner.pl/ -o mysqltuner.pl

COPY entrypoints/ /lagoon/entrypoints/
COPY mysql-backup.sh /lagoon/
COPY my.cnf /etc/mysql/my.cnf

RUN for i in /var/run/mysqld /var/lib/mysql /etc/mysql/conf.d /docker-entrypoint-initdb.d/ "${BACKUPS_DIR}" /home; \
    do mkdir -p $i; chown mysql $i; /bin/fix-permissions $i; \
    done

COPY root/usr/share/container-scripts/mysql/readiness-probe.sh /usr/share/container-scripts/mysql/readiness-probe.sh
RUN /bin/fix-permissions /usr/share/container-scripts/mysql/ \
    && /bin/fix-permissions /etc/mysql

RUN touch /var/log/mariadb-slow.log && /bin/fix-permissions /var/log/mariadb-slow.log \
    && touch /var/log/mariadb-queries.log && /bin/fix-permissions /var/log/mariadb-queries.log

# We cannot start mysql as root, we add the user mysql to the group root and
# change the user of the Docker Image to this user.
RUN addgroup mysql root
USER mysql
ENV USER_NAME mysql

WORKDIR /var/lib/mysql
VOLUME /var/lib/mysql
EXPOSE 3306

ENTRYPOINT ["/sbin/tini", "--", "/lagoon/entrypoints.bash"]
CMD ["mysqld"]
