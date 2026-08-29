# Local build helpers for the appdatabase composition function.
# CI does the real build (see .github/workflows/build-function.yml); this is
# for developing on a laptop.

IMAGE ?= function-appdatabase
TAG   ?= dev
# Where the .xpkg lands.
PKG   ?= _output/$(IMAGE)-$(TAG).xpkg

.PHONY: tidy test vet build image xpkg clean

tidy:
	go mod tidy

test: tidy
	go vet ./...
	go test ./...

# The runtime container image (the gRPC server distroless binary).
image: test
	docker build -t $(IMAGE)-runtime:$(TAG) .

# The Crossplane package (.xpkg). Embeds the runtime image so Crossplane only
# has to pull one artifact. Needs the `crossplane` CLI:
#   curl -sL https://raw.githubusercontent.com/crossplane/crossplane/main/install.sh | sh
xpkg: image
	mkdir -p _output
	crossplane xpkg build \
		--package-root=package \
		--embed-runtime-image=$(IMAGE)-runtime:$(TAG) \
		--package-file=$(PKG)
	@echo "built $(PKG)"

clean:
	rm -rf _output
