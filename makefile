# start project configuration
name := cedar
buildDir := build
testPackages := $(name) rest rest-data rest-model units operations model rpc-internal
allPackages := $(testPackages) benchmarks rpc
orgPath := github.com/evergreen-ci
projectPath := $(orgPath)/$(name)
# end project configuration

# start environment setup
gobin := go
ifneq (,$(GOROOT))
gobin := $(GOROOT)/bin/go
endif

goCache := $(GOCACHE)
ifeq (,$(goCache))
goCache := $(abspath $(buildDir)/.cache)
endif
goModCache := $(GOMODCACHE)
ifeq (,$(goModCache))
goModCache := $(abspath $(buildDir)/.mod-cache)
endif
lintCache := $(GOLANGCI_LINT_CACHE)
ifeq (,$(lintCache))
lintCache := $(abspath $(buildDir)/.lint-cache)
endif

ifeq ($(OS),Windows_NT)
gobin := $(shell cygpath $(gobin))
goCache := $(shell cygpath -m $(goCache))
goModCache := $(shell cygpath -m $(goModCache))
lintCache := $(shell cygpath -m $(lintCache))
export GOROOT := $(shell cygpath -m $(GOROOT))
endif

ifneq ($(goCache),$(GOCACHE))
export GOCACHE := $(goCache)
endif
ifneq ($(goModCache),$(GOMODCACHE))
export GOMODCACHE := $(goModCache)
endif
ifneq ($(lintCache),$(GOLANGCI_LINT_CACHE))
export GOLANGCI_LINT_CACHE := $(lintCache)
endif

ifneq (,$(RACE_DETECTOR))
# cgo is required for using the race detector.
export CGO_ENABLED := 1
else
export CGO_ENABLED := 0
endif
# end environment setup

# Ensure the build directory exists, since most targets require it.
$(shell mkdir -p $(buildDir))

.DEFAULT_GOAL := $(name)

# start lint setup targets
$(buildDir)/golangci-lint:
	@curl --retry 10 --retry-max-time 60 -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(buildDir) v1.64.5 >/dev/null 2>&1
$(buildDir)/run-linter:cmd/run-linter/run-linter.go $(buildDir)/golangci-lint $(buildDir)
	@$(gobin) build -o $@ $<
# end lint setup targets

# benchmark setup targets
$(buildDir)/run-benchmarks:cmd/run-benchmarks/run-benchmarks.go
	$(gobin) build -o $@ $<
# end benchmark setup targets

# start cli and distribution targets
$(name): $(buildDir)/$(name)
	@[ -e $@ ] || ln -s $<
$(buildDir)/$(name): .FORCE
	$(gobin) build -ldflags "-w -X github.com/evergreen-ci/cedar.BuildRevision=`git rev-parse HEAD`" -trimpath -o $@ cmd/$(name)/$(name).go
$(buildDir)/make-tarball:cmd/make-tarball/make-tarball.go
	@GOOS="" GOARCH="" $(gobin) build -o $@ $<
distContents := $(buildDir)/$(name)
dist: $(buildDir)/dist.tar.gz
$(buildDir)/dist.tar.gz: $(buildDir)/make-tarball $(distContents)
	./$< --name $@ --prefix $(name) $(foreach item,$(distContents),--item $(item)) --trim $(buildDir)
	tar -tvf $@
$(buildDir)/generate-points:cmd/generate-points/generate-points.go
	$(gobin) build -o $@ $<
generate-points:$(buildDir)/generate-points
	./$<
# end cli and distribution targets

# start output files
testOutput := $(foreach target,$(testPackages),$(buildDir)/output.$(target).test)
lintOutput := $(foreach target,$(allPackages),$(buildDir)/output.$(target).lint)
coverageOutput := $(foreach target,$(testPackages),$(buildDir)/output.$(target).coverage)
htmlCoverageOutput := $(foreach target,$(testPackages),$(buildDir)/output.$(target).coverage.html)
.PRECIOUS: $(lintOutput) $(testOutput) $(coverageOutput) $(htmlCoverageOutput)
# end output files

# start basic development targets
protocVersion := 3.19.3
protoOS := $(shell uname -s | tr A-Z a-z)
ifeq ($(protoOS),darwin)
protoOS := osx-x86_64
else
protoOS := $(protoOS)-$(shell uname -m | tr A-Z a-z)
endif
$(buildDir)/protoc:
	curl --retry 10 --retry-max-time 60 -L0 https://github.com/protocolbuffers/protobuf/releases/download/v$(protocVersion)/protoc-$(protocVersion)-$(protoOS).zip --output protoc.zip
	unzip -q protoc.zip -d $(buildDir)/protoc
	rm -f protoc.zip
	GOBIN="$(abspath $(buildDir))" $(gobin) install google.golang.org/protobuf/cmd/protoc-gen-go@latest
	GOBIN="$(abspath $(buildDir))" $(gobin) install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
proto: $(buildDir)/protoc
	PATH="$(abspath $(buildDir)):$(PATH)" $(buildDir)/protoc/bin/protoc --go_out=. --go-grpc_out=. *.proto
lint: $(lintOutput)
test: $(testOutput)
compile: $(buildDir)/$(name)
benchmark: $(buildDir)/run-benchmarks .FORCE
	./$(buildDir)/run-benchmarks
coverage: $(coverageOutput)
html-coverage: $(htmlCoverageOutput)
phony += compile lint test coverage html-coverage proto benchmark

# start convenience targets for running tests and coverage tasks on a
# specific package.
test-%:$(buildDir)/output.%.test
	
coverage-%:$(buildDir)/output.%.coverage
	
html-coverage-%:$(buildDir)/output.%.coverage.html
	
lint-%:$(buildDir)/output.%.lint
	
# end convenience targets
# end basic development targets

# start test and coverage artifacts
testArgs := -v -timeout=20m
ifneq (,$(RACE_DETECTOR))
testArgs += -race
endif
ifneq (,$(RUN_COUNT))
testArgs += -count=$(RUN_COUNT)
endif
ifneq (,$(RUN_TEST))
testArgs += -run='$(RUN_TEST)'
endif
ifneq (,$(SKIP_LONG))
testArgs += -short
endif
$(buildDir)/output.%.test: .FORCE
	$(gobin) test $(testArgs) ./$(if $(subst $(name),,$*),$(subst -,/,$*),) | tee $@
	@grep -s -q -e "^PASS" $@
$(buildDir)/output.%.coverage: .FORCE
	$(gobin) test $(testArgs) ./$(if $(subst $(name),,$*),$(subst -,/,$*),) -covermode=count -coverprofile $@ | tee $(buildDir)/output.$*.test
	@-[ -f $@ ] && $(gobin) tool cover -func=$@ | sed 's%$(projectPath)/%%' | column -t
	@grep -s -q -e "^PASS" $(subst coverage,test,$@)
$(buildDir)/output.%.coverage.html: $(buildDir)/output.%.coverage
	$(gobin) tool cover -html=$< -o $@

ifneq (go,$(gobin))
# We have to handle the PATH specially for linting in CI, because if the PATH has a different version of the Go
# binary in it, the linter won't work properly.
lintEnvVars := PATH="$(shell dirname $(gobin)):$(PATH)"
endif
$(buildDir)/output.%.lint: $(buildDir)/run-linter .FORCE
	@$(lintEnvVars) ./$< --output=$@ --lintBin=$(buildDir)/golangci-lint --packages='$*'
# end test and coverage artifacts

# start module management targets
mod-tidy:
	$(gobin) mod tidy
# Check if go.mod and go.sum are clean. If they're clean, then mod tidy should not produce a different result.
verify-mod-tidy:
	$(gobin) run cmd/verify-mod-tidy/verify-mod-tidy.go -goBin="$(gobin)"
phony += mod-tidy verify-mod-tidy
# end module management targets

# start mongodb targets
mongodb/.get-mongodb:
	rm -rf mongodb
	mkdir -p mongodb
	cd mongodb && curl "$(MONGODB_URL)" -o mongodb.tgz && $(MONGODB_DECOMPRESS) mongodb.tgz && chmod +x ./mongodb-*/bin/*
	cd mongodb && mv ./mongodb-*/bin/* . && rm -rf db_files && rm -rf db_logs && mkdir -p db_files && mkdir -p db_logs
mongodb/.get-mongosh:
	rm -rf mongosh
	mkdir -p mongosh
	cd mongosh && curl "$(MONGOSH_URL)" -o mongosh.tgz && $(MONGOSH_DECOMPRESS) mongosh.tgz && chmod +x ./mongosh-*/bin/*
	cd mongosh && mv ./mongosh-*/bin/* .
get-mongodb: mongodb/.get-mongodb
	@touch $<
get-mongosh: mongodb/.get-mongosh
	@touch $<
start-mongod: mongodb/.get-mongodb
	./mongodb/mongod --dbpath ./mongodb/db_files --port 27017 --replSet evg --oplogSize 10
	@echo "waiting for mongod to start up"
check-mongod: mongodb/.get-mongodb mongodb/.get-mongosh
	./mongosh/mongosh --nodb ./cmd/init-mongo/wait_for_mongo.js
	@echo "mongod is up"
init-rs: mongodb/.get-mongodb mongodb/.get-mongosh
	./mongosh/mongosh --eval 'rs.initiate()'
phony += get-mongodb get-mongosh start-mongod check-mongod init-rs
# end mongodb targets

# start cleanup targts
clean:
	rm -rf $(name) $(buildDir)
clean-results:
	rm -rf $(buildDir)/output.*
clean-proto:
	rm -rf $(buildDir)/protoc $(buildDir)/protoc-gen-go $(buildDir)/protoc-gen-go-grpc
phony += clean
# end cleanup targets

# configure phony targets
.FORCE:
.PHONY: $(phony) .FORCE
