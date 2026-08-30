# opnsense-observability

Kubernetes-native OPNsense monitoring: system health, firmware-update
alerts, dual-vantage-point internet connectivity, NetFlow traffic
analytics, and IDS alert triage — as a Helm chart for a cluster that
already runs a Prometheus Operator and Grafana.

Full design spec: `docs/superpowers/specs/2026-08-30-opnsense-observability-design.md`.

## Status

Core slice (`opnsense-exporter`, `blackbox-exporter`, connectivity/health
dashboards, alerts) implemented. NetFlow traffic analytics (Akvorado) and
IDS alert triage (EveBox) land in later releases.

## Prerequisites

See the design spec's §6 for the full, verified OPNsense-side checklist
(API user/key, `os-node_exporter` plugin, Unbound extended statistics,
monitor-only dpinger gateways).
