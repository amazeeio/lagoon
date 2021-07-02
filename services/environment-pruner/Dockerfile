ARG IMAGE_REPO
FROM ${IMAGE_REPO:-lagoon}/oc

ENV LAGOON=environment-pruner

RUN apk add --no-cache tini jq openssl bash curl nodejs nodejs-npm \
    && npm config set unsafe-perm true \
    && npm -g install jwtgen

COPY create_jwt.sh prune.sh /

ENV JWTSECRET=super-secret-string \
    JWTAUDIENCE=api.dev \
    PROJECT_REGEX=".+"  \
    ROUTER_LOG_INTERVAL=4h \
    POD_RUN_INTERVAL=14400 \
    ELASTICSEARCH_URL="http://logs-db-service:9200"

ENTRYPOINT ["/sbin/tini", "--", "/lagoon/entrypoints.sh"]
CMD ["/bin/docker-sleep"]
