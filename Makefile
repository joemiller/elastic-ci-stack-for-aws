.PHONY: all clean build packer upload

VERSION = $(shell git describe --tags --candidates=1)
SHELL = /bin/bash -o pipefail

PACKER_VERSION ?= 1.9.4
PACKER_LINUX_FILES = $(exec find packer/linux)
PACKER_WINDOWS_FILES = $(exec find packer/windows)

AWS_REGION ?= us-east-1

ARM64_INSTANCE_TYPE = m7g.xlarge
AMD64_INSTANCE_TYPE = m7a.xlarge
WIN64_INSTANCE_TYPE = m7i.xlarge

BUILDKITE_BUILD_NUMBER ?= none
BUILDKITE_PIPELINE_DEFAULT_BRANCH ?= main

IS_RELEASED ?= false
ifeq ($(BUILDKITE_BRANCH),$(BUILDKITE_PIPELINE_DEFAULT_BRANCH))
	IS_RELEASED = true
endif
ifeq ($(BUILDKITE_BRANCH),$(BUILDKITE_TAG))
	IS_RELEASED = true
endif

all: packer build

# Remove any built cloudformation templates and packer output
clean:
	-rm -rf build/*
	-rm packer*.output

# Check for specific environment variables
env-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "Environment variable $* not set"; \
		exit 1; \
	fi

# -----------------------------------------

build: packer build/mappings.yml build/aws-stack.yml

# Build a mapping file for a single region and image id pair
mappings-for-linux-amd64-image: env-AWS_REGION env-IMAGE_ID
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { linuxamd64: %s, linuxarm64: '', windows: '' }\n" \
		"$(AWS_REGION)" $(IMAGE_ID) > build/mappings.yml

# Build a mapping file for a single region and image id pair
mappings-for-linux-arm64-image: env-AWS_REGION env-IMAGE_ID
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { linuxamd64: '', linuxarm64: %s, windows: '' }\n" \
		"$(AWS_REGION)" $(IMAGE_ID) > build/mappings.yml

# Build a windows mapping file for a single region and image id pair
mappings-for-windows-amd64-image: env-AWS_REGION env-IMAGE_ID
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { linuxamd64: '', linuxarm64: '', windows: %s }\n" \
		"$(AWS_REGION)" $(IMAGE_ID) > build/mappings.yml

# Takes the mappings files and copies them into a generated stack template
.PHONY: build/aws-stack.yml
build/aws-stack.yml:
	test -f build/mappings.yml
	awk '{ \
		if ($$0 ~ /AWSRegion2AMI:/ && system("test -f build/mappings.yml") == 0) { \
			system("grep -v Mappings: build/mappings.yml") \
		} else { \
			print \
		}\
	}' templates/aws-stack.yml | sed "s/%v/$(VERSION)/" > $@

# -----------------------------------------
# AMI creation with Packer

packer: packer-linux-amd64.output packer-linux-arm64.output packer-windows-amd64.output

build/mappings.yml: build/linux-amd64-ami.txt build/linux-arm64-ami.txt build/windows-amd64-ami.txt
	mkdir -p build
	printf "Mappings:\n  AWSRegion2AMI:\n    %q : { linuxamd64: %q, linuxarm64: %q, windows: %q }\n" \
		"$(AWS_REGION)" $$(cat build/linux-amd64-ami.txt) $$(cat build/linux-arm64-ami.txt) $$(cat build/windows-amd64-ami.txt) > $@

build/linux-amd64-ami.txt: packer-linux-amd64.output env-AWS_REGION
	mkdir -p build
	grep -Eo "$(AWS_REGION): (ami-.+)" $< | cut -d' ' -f2 | xargs echo -n > $@

# Build linux packer image
packer-linux-amd64.output: $(PACKER_LINUX_FILES)
	docker run \
		-e AWS_DEFAULT_REGION  \
		-e AWS_PROFILE \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e PACKER_LOG \
		-v ${HOME}/.aws:/root/.aws \
		-v "$(PWD):/src" \
		--rm \
		-w /src/packer/linux \
		hashicorp/packer:full-$(PACKER_VERSION) build -timestamp-ui \
			-var 'region=$(AWS_REGION)' \
			-var 'arch=x86_64' \
			-var 'instance_type=$(AMD64_INSTANCE_TYPE)' \
			-var 'build_number=$(BUILDKITE_BUILD_NUMBER)' \
			-var 'is_released=$(IS_RELEASED)' \
			buildkite-ami.pkr.hcl | tee $@

build/linux-arm64-ami.txt: packer-linux-arm64.output env-AWS_REGION
	mkdir -p build
	grep -Eo "$(AWS_REGION): (ami-.+)" $< | cut -d' ' -f2 | xargs echo -n > $@

CURRENT_AGENT_VERSION_LINUX ?= $(shell sed -En 's/^AGENT_VERSION="?(.+?)"?$/\1/p' packer/linux/scripts/install-buildkite-agent.sh)
CURRENT_AGENT_VERSION_WINDOWS ?= $(shell sed -En 's/^\$AGENT_VERSION = "(.+?)"$/\1/p' packer/windows/scripts/install-buildkite-agent.ps1)

# Build linuxarm64 packer image
packer-linux-arm64.output: $(PACKER_LINUX_FILES)
	docker run \
		-e AWS_DEFAULT_REGION  \
		-e AWS_PROFILE \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e PACKER_LOG \
		-v ${HOME}/.aws:/root/.aws \
		-v "$(PWD):/src" \
		--rm \
		-w /src/packer/linux \
		hashicorp/packer:full-$(PACKER_VERSION) build -timestamp-ui \
			-var 'region=$(AWS_REGION)' \
			-var 'arch=arm64' \
			-var 'instance_type=$(ARM64_INSTANCE_TYPE)' \
			-var 'build_number=$(BUILDKITE_BUILD_NUMBER)' \
			-var 'is_released=$(IS_RELEASED)' \
			-var 'agent_version=$(CURRENT_AGENT_VERSION_LINUX)' \
			buildkite-ami.pkr.hcl | tee $@

build/windows-amd64-ami.txt: packer-windows-amd64.output env-AWS_REGION
	mkdir -p build
	grep -Eo "$(AWS_REGION): (ami-.+)" $< | cut -d' ' -f2 | xargs echo -n > $@

# Build windows packer image
packer-windows-amd64.output: $(PACKER_WINDOWS_FILES)
	docker run \
		-e AWS_DEFAULT_REGION  \
		-e AWS_PROFILE \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e PACKER_LOG \
		-v ${HOME}/.aws:/root/.aws \
		-v "$(PWD):/src" \
		--rm \
		-w /src/packer/windows \
		hashicorp/packer:full-$(PACKER_VERSION) build -timestamp-ui \
			-var 'region=$(AWS_REGION)' \
			-var 'arch=x86_64' \
			-var 'instance_type=$(WIN64_INSTANCE_TYPE)' \
			-var 'build_number=$(BUILDKITE_BUILD_NUMBER)' \
			-var 'is_released=$(IS_RELEASED)' \
			-var 'agent_version=$(CURRENT_AGENT_VERSION_WINDOWS)' \
			buildkite-ami.pkr.hcl | tee $@

# -----------------------------------------
# Cloudformation helpers

config.json:
	cp config.json.example config.json

SERVICE_ROLE=
ifdef SERVICE_ROLE
	role_arn="--role-arn=$(SERVICE_ROLE)"
endif

create-stack: build/aws-stack.yml env-STACK_NAME
	aws cloudformation create-stack \
		--output text \
		--stack-name $(STACK_NAME) \
		--disable-rollback \
		--template-body "file://$(PWD)/build/aws-stack.yml" \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
		--parameters "$$(cat config.json)" \
		"$(role_arn)"

update-stack: build/aws-stack.yml env-STACK_NAME
	aws cloudformation update-stack \
		--output text \
		--stack-name $(STACK_NAME) \
		--template-body "file://$(PWD)/build/aws-stack.yml" \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
		--parameters "$$(cat config.json)" \
		"$(role_arn)"

# -----------------------------------------
# Other

AGENT_VERSION ?= $(shell curl -Lfs "https://buildkite.com/agent/releases/latest?platform=linux&arch=amd64" | grep version | cut -d= -f2)

bump-agent-version:
	sed -i.bak -E "s/\[Buildkite Agent v.*\]/[Buildkite Agent v$(AGENT_VERSION)]/g" README.md
	sed -i.bak -E "s/AGENT_VERSION=.+/AGENT_VERSION=$(AGENT_VERSION)/g" packer/linux/scripts/install-buildkite-agent.sh
	sed -i.bak -E "s/\\\$$AGENT_VERSION = \".+\"/\$$AGENT_VERSION = \"$(AGENT_VERSION)\"/g" packer/windows/scripts/install-buildkite-agent.ps1
	rm README.md.bak packer/linux/scripts/install-buildkite-agent.sh.bak packer/windows/scripts/install-buildkite-agent.ps1.bak

validate: build/aws-stack.yml
	aws --no-cli-pager cloudformation validate-template \
		--output text \
		--template-body "file://$(PWD)/build/aws-stack.yml"

generate-toc:
	docker run -it --rm -v "$(PWD):/app" node:slim bash \
		-c "npm install -g markdown-toc && cd /app && markdown-toc -i README.md"
