# SPDX-License-Identifier: Apache-2.0
# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# test-commit runs inside the kube-devenv image. test-integration needs a
# kind cluster that kubectl can reach; CI creates one before calling it.
#   BASE_REF  commit the branch started from; empty skips commit-messages

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)
RELEASE  := opnsense-observability-ci
PROM_CRDS := https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd

export REQUIRE_SIGNOFF ?= 0

.PHONY: test-commit test-fast test-integration hooks repo helm-unittest ct-lint \
	lint-pipelines secrets commit-messages install-core install-full

test-commit: test-fast helm-unittest ct-lint lint-pipelines commit-messages

test-fast: secrets

hooks:
	git config core.hooksPath .githooks

repo:
	helm repo add redpanda https://charts.redpanda.com --force-update

helm-unittest: repo
	helm unittest .

ct-lint: repo
	ct lint --config ct.yaml

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .
	tests/check-gitlab-ci.sh

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"

test-integration: install-core install-full

install-core: repo
	kubectl apply --server-side -f $(PROM_CRDS)/monitoring.coreos.com_servicemonitors.yaml
	kubectl apply --server-side -f $(PROM_CRDS)/monitoring.coreos.com_probes.yaml
	kubectl apply --server-side -f $(PROM_CRDS)/monitoring.coreos.com_prometheusrules.yaml
	kubectl apply -f ci/core-secret.yaml
	helm dependency update .
	helm install $(RELEASE) . -f ci/core-values.yaml --wait --timeout 5m
	kubectl get pods -o wide
	kubectl wait --for=condition=Ready pod --all --timeout=60s

install-full:
	helm upgrade $(RELEASE) . -f ci/core-values.yaml -f ci/full-values.yaml --wait --timeout 8m
	kubectl get pods -o wide
	kubectl wait --for=condition=Ready pod --all --timeout=120s --field-selector=status.phase!=Succeeded
