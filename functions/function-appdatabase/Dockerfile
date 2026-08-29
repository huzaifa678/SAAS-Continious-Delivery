# syntax=docker/dockerfile:1

# --- Build the function runtime binary --------------------------------------
# Uses the committed go.mod/go.sum; the resulting binary is fully static.
FROM golang:1.24 AS build

WORKDIR /fn
ENV CGO_ENABLED=0

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go vet ./... && go test ./...
RUN go build -o /function .

# --- Minimal runtime image --------------------------------------------------
# distroless static: no shell, no package manager. Crossplane runs this as the
# Function's runtime container; it serves gRPC on :9443.
FROM gcr.io/distroless/static-debian12:nonroot AS image

WORKDIR /
COPY --from=build /function /function
EXPOSE 9443
USER nonroot:nonroot
ENTRYPOINT ["/function"]
