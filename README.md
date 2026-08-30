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

## Reaching os-node_exporter on the firewall

This chart has no built-in way to scrape `os-node_exporter` running on the
OPNsense firewall itself — it's an out-of-cluster target. Use the generic
`extraObjects` escape hatch (arbitrary extra manifests rendered alongside
this chart) to add a headless Service + matching Endpoints pointing at the
firewall's LAN IP and port `9100`, so your cluster Prometheus can scrape it
like any other target:

```yaml
extraObjects:
  - apiVersion: v1
    kind: Service
    metadata:
      name: os-node-exporter
    spec:
      clusterIP: None
      ports:
        - name: http
          port: 9100
  - apiVersion: v1
    kind: Endpoints
    metadata:
      name: os-node-exporter
    subsets:
      - addresses:
          - ip: 192.168.1.1   # firewall's LAN IP
        ports:
          - name: http
            port: 9100
```

Add a `ServiceMonitor` (or point your Prometheus's existing selector at
this Service) to complete the scrape config. Each `extraObjects` entry is
rendered with Helm's `tpl`, so `.Release`/`.Values` are usable inside if
needed.
