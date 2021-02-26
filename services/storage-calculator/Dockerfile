ARG IMAGE_REPO
FROM ${IMAGE_REPO:-lagoon}/oc

ARG LAGOON_VERSION
ENV LAGOON_VERSION=$LAGOON_VERSION

ENV LAGOON=storage-calculator

RUN apk add --no-cache tini jq bash curl py3-jwt
RUN pip install yq

COPY create_jwt.py api-query.sh calculate-storage.sh process-deployment-target.sh process-project.sh /

ENV JWTSECRET=super-secret-string \
    JWTAUDIENCE=api.dev \
    PROJECT_REGEX=".+"

ENTRYPOINT ["/sbin/tini", "--", "/lagoon/entrypoints.sh"]
CMD ["/bin/docker-sleep"]
