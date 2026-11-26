# syntax=docker/dockerfile:1
# Build from this directory: docker build -t ghenti/glide-api services/api
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm@sha256:ea47ee45f1284d60f9cc09cb2c3bb4f508c256b640bd8bb30342ff13d1adcb52 AS api
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/glide-api ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=api /out/glide-api /glide-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/glide-api"]
