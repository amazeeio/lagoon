ARG ALPINE_VERSION=3.12

FROM golang:1-alpine AS builder
ARG LAGOON_VERSION=development
WORKDIR /go/src/app
COPY . .
RUN apk add --no-cache make git \
      && go get -u github.com/go-bindata/go-bindata/... \
      && make build VERSION="${LAGOON_VERSION}"

FROM alpine:${ALPINE_VERSION}
COPY --from=builder /go/src/app/ssh-portal /ssh-portal
ENTRYPOINT /ssh-portal
