VERSION ?= $(shell git describe --always)

.PHONY: push
push: image
	docker push smlx/ssh-portal

.PHONY: image
image:
	docker build . --build-arg=LAGOON_VERSION=$$(git describe --always) --tag smlx/ssh-portal

.PHONY: build
build:
	go generate ./...
	CGO_ENABLED=0 go build -ldflags "-X main.version=$(VERSION) -X main.buildTime=$$(date -u +"%Y-%m-%dT%H:%M:%SZ")" .
