# One Dockerfile, three binaries, selected by --build-arg BINARY.

FROM golang:1.25-alpine AS build
WORKDIR /src

# Cached until go.mod or go.sum changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG BINARY
# CGO off gives a static binary, so the runtime stage needs no libc.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${BINARY}

FROM alpine:3.20
# The worker POSTs to arbitrary https URLs and needs a trust store.
RUN apk add --no-cache ca-certificates
COPY --from=build /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
