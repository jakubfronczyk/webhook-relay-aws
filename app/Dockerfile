# One Dockerfile, three binaries, selected by --build-arg BINARY.
# The build is identical for api, worker and sink, so two near-identical
# Dockerfiles would only be two places to forget to update.

FROM golang:1.25-alpine AS build
WORKDIR /src

# Dependencies first: this layer is cached until go.mod or go.sum changes, so an
# app-code edit rebuilds in seconds instead of re-downloading the AWS SDK.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG BINARY
# CGO off gives a static binary, so the runtime stage needs no libc at all.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${BINARY}

FROM alpine:3.20
# The worker POSTs to arbitrary https subscriber URLs, so it needs a trust store.
RUN apk add --no-cache ca-certificates
COPY --from=build /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
