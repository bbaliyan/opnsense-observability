# opnsense-observability

Kubernetes-native OPNsense monitoring: system health, firmware-update
alerts, dual-vantage-point internet connectivity, NetFlow traffic
analytics, and IDS alert triage — as a Helm chart for a cluster that
already runs a Prometheus Operator and Grafana.

Full design spec: `docs/design.md`.

## Status

Core slice (`opnsense-exporter`, `blackbox-exporter`, connectivity/health
dashboards, alerts), NetFlow traffic analytics (Akvorado), and IDS alert
triage (EveBox) all implemented.

## Prerequisites

See the design spec's §6 for the full, verified OPNsense-side checklist
(API user/key, `os-node_exporter` plugin, Unbound extended statistics,
monitor-only dpinger gateways).

### NetFlow traffic analytics (optional — `akvorado.enabled: true`)

1. Install the chart with `akvorado.enabled: true` (see `examples/full-values.yaml`).
2. Find the `akvorado-inlet` Service's address:
   `kubectl get svc <release>-akvorado-inlet -o wide`
3. On OPNsense: **Reporting → Netflow**. Enable capture, select **WAN**
   (and **LAN** if you also want internal-to-internal visibility), set
   **Netflow version** to **v9**, and set the target to the inlet Service
   address from step 2, port `2055`.
4. GeoIP data (destination-country panel) comes from
   [DB-IP Lite](https://db-ip.com/db/lite.php) — free, no account or
   license key, refreshed monthly by an in-chart CronJob. Attribution:
   this product includes GeoLite2 data created by DB-IP, distributed
   under the [CC BY 4.0 license](https://creativecommons.org/licenses/by/4.0/).
5. The Akvorado console and traffic dashboard need a Grafana ClickHouse
   datasource pointed at the `<release>-clickhouse` Service (port `9000`)
   — this chart does not provision Grafana datasources (see Non-goals),
   so add one via your Grafana provisioning of choice. ClickHouse's default
   user has no password — acceptable since the Service is a plain
   ClusterIP never exposed outside the cluster, but worth knowing before
   running this chart on a shared/multi-tenant cluster.
6. The inlet's NetFlow Service uses `externalTrafficPolicy: Local` to
   preserve OPNsense's real source IP (Akvorado attributes flows by
   source address). This requires a `LoadBalancer` implementation that
   preserves client IPs — true for MetalLB and most cloud load balancers.
7. Akvorado's four workloads (orchestrator, inlet, outlet, console) run
   as root (UID 0), since the upstream `quay.io/akvorado/akvorado` image
   has no non-root user. They will not schedule in a namespace enforcing
   the `restricted` Pod Security Standard — only `baseline` or
   `privileged` namespaces work.

### IDS alert triage (optional — `evebox.enabled: true`)

1. Install the chart with `evebox.enabled: true` (see `examples/full-values.yaml`).
2. On OPNsense: **Services → Intrusion Detection → Administration**, enable
   **EVE JSON** output (Suricata itself must already be enabled and running
   — this chart assumes IDS is already turned on, per the design spec's
   §6 step 6 prior-state note).
3. Install the [EveBox Agent](https://evebox.org/docs/agent/) on OPNsense.
   This is a small binary, **not** an OPNsense plugin (no entry in
   Firmware → Plugins) — the one deliberate exception in this design to
   "every OPNsense-side piece is a native, already-shipping feature."
4. The `evebox` Service needs to be reachable from OPNsense — with the
   shipped defaults (`evebox.service.type: ClusterIP`, Ingress disabled)
   it is cluster-internal only, and the Agent (which runs on OPNsense,
   outside the cluster) can't reach it. Pick one:
   - Enable `evebox.ingress` (see `examples/full-values.yaml`, which sets
     `host: "ids.home.example"`) and point the Agent at that host.
   - Or set `evebox.service.type: LoadBalancer` (same approach as
     `akvorado.netflow.serviceType`) and find the address:
     `kubectl get svc <release>-evebox -o wide`.
5. Configure the Agent to tail Suricata's EVE JSON file and ship to
   whichever address you exposed in step 4, e.g. for the Ingress path:
   ```yaml
   server:
     url: http://ids.home.example
   input:
     paths:
       - "/var/log/suricata/eve.json"
   ```
   (For the `LoadBalancer` path, use that Service's external address and
   `evebox.service.port`, `5636` by default, instead. This chart doesn't
   manage TLS termination, so use `http://` unless you've set up your own
   TLS at the Ingress.)
6. EveBox's own authentication is disabled (`--no-auth`). Treat whichever
   address you exposed in step 4 as trusted-network-only — don't expose
   it to the public internet without your own network-level protection
   (VPN, firewall allowlist, etc.). Don't put an authenticating reverse
   proxy in front of it: the Agent's ingest traffic travels the same
   path as browser access, so an authenticating proxy would also block
   the Agent from ever delivering events.
7. EveBox runs as root (UID 0) — confirmed against the real
   `jasonish/evebox` image, which has no non-root user. It will not
   schedule in a namespace enforcing the `restricted` Pod Security
   Standard — only `baseline` or `privileged` namespaces work (same
   caveat as Akvorado, above).
8. EveBox exposes no Prometheus metrics endpoint — this chart ships no
   ServiceMonitor or PrometheusRule for it. Alert triage happens in
   EveBox's own web UI; pod health is covered by the usual
   Kubernetes-level Deployment status.

## Values reference

| Key | Description |
| --- | --- |
| `opnsenseExporter.enabled` | Deploy opnsense-exporter, which polls the OPNsense REST API. |
| `opnsenseExporter.opnsense.address` | OPNsense firewall address (required). |
| `opnsenseExporter.opnsense.apiKeySecretRef` / `apiSecretSecretRef` | Secret references for the read-only API user/key (see Prerequisites). |
| `blackboxExporter.enabled` | Deploy blackbox-exporter for cluster-side ICMP probes. |
| `blackboxExporter.wanGatewayAddress` | OPNsense WAN gateway IP to probe (required). |
| `blackboxExporter.probeSelectorLabels` | Labels matching the cluster Prometheus's `probeSelector`. |
| `akvorado.enabled` | Turn on the NetFlow traffic-analytics pipeline (Redpanda + ClickHouse + Akvorado orchestrator/inlet/outlet/console). Default `false`. |
| `akvorado.netflow.serviceType` | Service type for the inlet's NetFlow listener; typically `LoadBalancer` so OPNsense on the LAN can reach it. |
| `akvorado.geoip.enabled` | Auto-download DB-IP Lite GeoIP databases via an in-chart CronJob. |
| `akvorado.kafka.brokers` | External Kafka broker list; empty (default) uses the bundled Redpanda's internal listener. |
| `akvorado.clickhouse.persistence.size` | PVC size for the vendored single-node ClickHouse StatefulSet. |
| `akvorado.console.ingress.enabled` | Expose the Akvorado console via Ingress. |
| `evebox.enabled` | Deploy the EveBox server for Suricata IDS alert triage. Default `false`. |
| `evebox.service.type` | Service type for EveBox; set to `LoadBalancer` (or use `evebox.ingress`) so the OPNsense-side Agent can reach it — see IDS alert triage prerequisites. |
| `evebox.service.port` | Port the EveBox server listens on and the Agent ships to. |
| `evebox.persistence.size` | PVC size for EveBox's SQLite data (events + FTS index). |
| `evebox.ingress.enabled` | Expose the EveBox UI via Ingress. |
| `extraObjects` | Escape hatch for arbitrary extra manifests rendered alongside this chart (see below). |

See `values.yaml` for the full set of keys, including passthrough values for
the `blackbox-exporter` and `redpanda` subcharts.

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
