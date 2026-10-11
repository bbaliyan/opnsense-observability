# opnsense-observability

A Helm chart that turns an OPNsense firewall into a fully observable part of
your Kubernetes monitoring stack: system and service health, firmware-update
alerting, internet-connectivity and outage visibility, NetFlow traffic
analytics, and Suricata IDS alert triage — delivered as Grafana dashboards and
Prometheus alert rules.

## Requirements

- A **Prometheus Operator** in the cluster, providing the `ServiceMonitor`
  and `PrometheusRule` CRDs.
- A **Grafana** that loads dashboards from ConfigMaps via the dashboard sidecar
  convention (`grafana_dashboard: "1"` label).

This chart deploys neither of those, nor Alertmanager, nor Loki. It also does
not provision Grafana datasources — you add a **Prometheus** datasource
yourself, plus a **ClickHouse** datasource if you enable NetFlow analytics.

## How it works

Nothing this chart installs runs on the firewall. Every collector lives in the
cluster; on the OPNsense side you switch on features that already ship with the
product and point them at cluster addresses.

Two signals are **pulled** by the cluster:

- `opnsense-exporter` polls the OPNsense REST API over HTTPS for firmware
  status, service status, interface counters, gateway health, and Unbound DNS
  statistics.
- Prometheus scrapes the `os-node_exporter` plugin on the firewall directly on
  port 9100 for host CPU, memory, disk, and load metrics.

Two signals are **pushed** by the firewall:

- NetFlow v9 records go to the Akvorado inlet on UDP 2055.
- Suricata EVE JSON goes over TCP syslog to the EveBox pod's syslog listener.

Push direction is the reason those two endpoints cannot stay `ClusterIP`. The
firewall lives outside the cluster and initiates the connection, so each needs
an address routable from the LAN. The defaults are not symmetric:
`akvorado.netflow.serviceType` is already `LoadBalancer`, while
`evebox.syslog.service.type` defaults to `ClusterIP` and you must set it to
`LoadBalancer` (or otherwise publish it) yourself. Forgetting that is the
single most common setup mistake.

| Signal | Direction | Protocol / port | Firewall side | Cluster side |
| --- | --- | --- | --- | --- |
| System, service, firmware, gateway, Unbound metrics | Cluster pulls | HTTPS 443 (REST API) | Read-only API user + key | `opnsense-exporter` Deployment, scraped via ServiceMonitor |
| Host CPU / memory / disk / load | Cluster pulls | HTTP 9100 | `os-node_exporter` plugin | Prometheus scrape of an `extraObjects` Service + Endpoints |
| NetFlow records | Firewall pushes | UDP 2055 | Reporting → Netflow target | `<release>-akvorado-inlet` Service (`LoadBalancer` by default) |
| Suricata EVE JSON | Firewall pushes | TCP syslog, RFC5424 | Logging target scoped to `suricata` | `<release>-evebox-syslog` Service (`ClusterIP` by default — publish it) |

What Grafana reads: **Prometheus** for the Internet & Firewall dashboard,
**ClickHouse** for the traffic dashboard.

### The Internet & Firewall dashboard

It opens with the internet connection: current download and upload speed (the
last hour as a sparkline), the peak and the total transferred in the chosen
range, and a speed chart. Then come the gateways from the firewall's own
dpinger monitoring (status, RTT, jitter and loss), the firewall (service
status, TCP connections by state, passed and blocked IPv4 packets, per-interface
rule statistics), and a system section adapted from grafana.com dashboard 19366
(CPU, memory, swap, load, interrupts, per-interface packets, multicast, drops
and errors). Loss is drawn as bars on a 0-2 % axis that grows only when loss is
higher, with the worst loss, average loss and minutes with any loss for the
chosen range beside it, so a 1 % blip is easy to see.

It has these pickers, because it draws on two independent scrape targets:

- **OPNsense Instance** selects the `opnsense_instance` label the exporter
  stamps on its own metrics: the value of
  `opnsenseExporter.opnsense.instanceLabel`. It drives the gateway, service,
  TCP-state, firewall and interface panels.
- **Firewall node_exporter Target** selects the `instance` label of the
  `os-node_exporter` scrape target on the firewall (e.g. `192.168.1.1:9100`).
  It drives the uptime, CPU, load, memory, swap, interrupt and WAN/LAN speed
  panels.
- **Gateway** and **Firewall Interface** scope the connectivity panels and the
  per-interface firewall panels. Both default to all values.
- **WAN Interface** and **LAN Interface** take OPNsense's interface names
  (default `WAN` and `LAN`). The dashboard resolves them to NIC devices (`ix0`,
  `vtnet1`, and so on) through the exporter's `opnsense_interfaces_*` metrics.

The two instance labels are different label spaces and will almost never hold
the same string, so set both. A virtualized firewall can't read the CPU's
temperature sensors, so the temperature panel shows the physical server's CPU
temperature from an iDRAC exporter (`idrac_sensors_temperature`); without that
metric it stays empty. The per-second panels need a scrape interval of 30 s or
shorter.


**EveBox is its own web UI, not a Grafana datasource.** It stores events in its
own SQLite database and serves its own alert-triage interface on port 5636. No
Grafana dashboard in this chart reads EveBox data, and there is no way to make
one — you open EveBox directly.

### Gateway status semantics

`opnsense_gateways_status` reports three states: `0` Offline, `1` Online,
`2` Unknown. Alerting and dashboards treat anything other than `1` as not
healthy.

## OPNsense setup

Work through these in order. Steps 1 and 2 are needed for the core install.
Step 3 is optional and adds raw Unbound DNS metrics only. Steps 4, 5 and 6
unlock connectivity, NetFlow, and IDS features respectively.

### 1. Read-only API user and key

`opnsense-exporter` authenticates against the REST API — OPNsense has no
anonymous API mode, so this step is unavoidable.

1. **System → Access → Groups → +**. Create a group, e.g.
   `opnsense-exporter-ro`. In *Assigned Privileges*, use the search box and
   tick entries under **Status**, **Diagnostics**, **Reporting**, **Services**
   (Unbound DNS, plus whichever of OpenVPN / IPsec / WireGuard / Kea DHCP you
   run), and **System → Firmware** and **System → Gateways**. Grant nothing
   under System → Access, and no full-admin privilege. Exact checkbox wording
   shifts between OPNsense releases, so search rather than hunting a menu tree.
2. **System → Access → Users → +**. Create a user, e.g.
   `svc-opnsense-exporter`, with a long random password (never used — this
   account authenticates by API key only) and group membership set to only the
   group from step 1.
3. Reopen that user → **API keys → +**. OPNsense generates and downloads a
   key/secret pair immediately. It is shown once; losing it means regenerating,
   which invalidates the old pair.

Store the pair in a Kubernetes Secret and reference it from values:

```bash
kubectl create secret generic opnsense-api \
  --from-literal=api-key='<key>' \
  --from-literal=api-secret='<secret>'
```

```yaml
opnsenseExporter:
  opnsense:
    address: "192.168.1.1"
    apiKeySecretRef: {name: opnsense-api, key: api-key}
    apiSecretSecretRef: {name: opnsense-api, key: api-secret}
```

Sanity-check the credentials before installing:

```bash
curl -sk -u "<key>:<secret>" https://192.168.1.1/api/core/firmware/status
```

A `200` with JSON is good; `401` means a bad key/secret; `403` means the key is
valid but the group is missing a privilege.

### 2. os-node_exporter plugin

**This step is not optional in practice.** Many panels on the Internet & Firewall
dashboard — uptime, temperature, CPU usage and utilization, load average,
memory, swap, interrupts, context switches, filesystem, disk I/O and disk IOPS
— read `node_*` metrics. Without this plugin and its scrape target, much of the
dashboard shows "No data".

1. **Firmware → Plugins** → search `os-node_exporter` → install.
2. **Services → Prometheus Exporter**: check *Enabled*, set *Listen Address* to
   `0.0.0.0`, leave *Listen Port* at `9100`, leave all collectors enabled
   (none are expensive at single-firewall scale). Save.
3. Verify: `curl -s http://192.168.1.1:9100/metrics | head`.
4. Give the cluster a scrape target for it using the `extraObjects` snippet in
   [Scraping os-node_exporter on the firewall](#scraping-os-node_exporter-on-the-firewall).

The endpoint is unauthenticated by design — the same trust model as any
node_exporter. Keep it LAN-only through your firewall rules.

### 3. Unbound extended statistics (optional)

`opnsense-exporter` surfaces a narrow slice of Unbound's extended data —
`opnsense_unbound_*` metrics covering DNSSEC secure and bogus answer counts and
resolver uptime. That narrow slice is an upstream exporter limitation.
**No dashboard shipped by this chart renders those metrics, and no alert rule
uses them.** Turn the setting on if you want to build your own panels or
queries against them; skip this step otherwise.

**Services → Unbound DNS → Advanced → Logging Settings → Extended
Statistics** → check → Apply.

The toggle is easy to miss: it is not on the General page, and the separate
*Statistics* sidebar item is display-only — it shows basic counters whether or
not extended statistics is on, so it cannot be used to verify the setting.

### 4. Gateway monitoring for internet targets

The firewall's own dpinger gateway monitoring is what makes an internet outage
visible and alertable. Add one monitor-only gateway entry per target you want
tracked (e.g. `1.1.1.1`, `8.8.8.8`).

**System → Gateways → Configuration → +**, then for each entry:

| Field | Value | Why |
| --- | --- | --- |
| Interface | WAN | Same physical path as the real WAN gateway |
| Address Family | IPv4 | |
| Priority | 255 (form default) | Lowest preference — never wins as a default route |
| **IP Address** | the target itself, e.g. `1.1.1.1` | Not the WAN's DHCP-assigned gateway IP, which goes stale when the ISP reassigns it |
| **Far Gateway** | **checked** | Required — the target is off-link, so OPNsense must route via WAN's default route instead of expecting ARP for it |
| Disable Gateway Monitoring | unchecked | dpinger monitoring is the entire point |
| Disable Host Route | unchecked | Checking it can prevent the route needed to reach the far gateway at all |
| Monitor IP | blank | With Far Gateway set, dpinger monitors *IP Address* itself |

Leaving **Far Gateway** unchecked is the likeliest mistake — the form accepts an
off-link *IP Address* either way, but monitoring will not work correctly.

Do **not** select these entries as any interface's default gateway, and do not
add them to a Gateway Group used by firewall rules. Leaving them alone is what
keeps them monitor-only, with no routing impact.

Confirm each row appears on the Gateways list with RTT / RTTd / Loss columns
populating within a few seconds. No service restart is needed. The Connectivity
dashboard offers a `$gateway` template variable to pick between whatever
gateways exist, and the gateway-down alert covers all of them.

### 5. NetFlow export

Only relevant with `akvorado.enabled: true`.

1. Install the chart, then find the inlet's address:
   `kubectl get svc <release>-akvorado-inlet -o wide`
2. **Reporting → Netflow**: enable capture, select **WAN** (and **LAN** too if
   you want internal-to-internal visibility), set **Netflow version** to **v9**,
   and set the target to the inlet address on port `2055`.

### 6. Suricata EVE syslog output

Only relevant with `evebox.enabled: true`. Suricata must already be enabled and
running on the firewall — this chart assumes IDS is turned on.

1. **Services → Intrusion Detection → Administration** → enable **EVE syslog
   output**.
2. Find the syslog listener's address:
   `kubectl get svc <release>-evebox-syslog -o wide`
3. **System → Settings → Logging / Targets → +**. Add a target with
   **Transport: TCP**, **Format: RFC5424**, and the hostname/port from step 2
   (port `5140` by default).
4. **Set *Applications* on that target to `suricata`, and nothing else.** This
   is not optional tidiness. A logging target left at its default ships *every*
   application's messages — pf/filterlog, unbound, dhcpd, kernel — to the
   syslog listener. Those lines are not EVE JSON, so EveBox logs a parse error
   for each one, and on a busy firewall they arrive at many times the IDS event
   rate. The spool shares the EveBox PVC with the SQLite database, so an
   unscoped target inflates both. The Vector sidecar also drops anything whose
   syslog application name is not `suricata`, but scope the target anyway — no
   reason to ship the traffic at all.

**TCP is required, not a preference.** EVE lines that carry packet payloads
exceed the practical UDP datagram size; over UDP they are truncated into
invalid JSON and silently dropped. Transport is only half of it: the sending
side has its own maximum syslog message size (syslog-ng's `log_msg_size` on
OPNsense), which truncates long EVE lines before they ever reach the wire. If
long events arrive truncated even over TCP, raise that limit on the firewall.

## IDS alert triage

With `evebox.enabled: true` the chart runs a single EveBox pod containing two
containers: a Vector sidecar that terminates TCP syslog, strips the RFC5424
envelope, and appends the recovered EVE JSON lines to a spool file; and the
EveBox server, which reads that same spool file and indexes events into SQLite.

Two Services are created, deliberately split:

| Service | Port | Purpose |
| --- | --- | --- |
| `<release>-evebox` | 5636 | Web UI only |
| `<release>-evebox-syslog` | 5140 | Syslog listener only |

Set `evebox.syslog.service.type: LoadBalancer` — it defaults to `ClusterIP`,
which the firewall cannot reach. Reach the **web UI** through `evebox.ingress` or a port-forward.

The split exists for a reason. EveBox runs with authentication disabled
(`--no-auth`), so publishing the UI Service on the LAN would put an
unauthenticated IDS console on your network. Keep the UI Service `ClusterIP`
and expose only the syslog Service. `evebox.ingress` serves the web UI only — a
plain HTTP Ingress does not carry syslog, so it is never an answer to the
reachability question for EVE data.

Whatever address you do expose, treat it as trusted-network-only. Do not put
the UI on the public internet without network-level protection of your own
(VPN, firewall allowlist).

Operational notes:

- The EVE spool lives on the EveBox PVC at `/var/lib/evebox/spool/eve.json`,
  shared between the Vector sidecar (writer) and EveBox (reader). It grows over
  time and is not rotated, and it shares the PVC with the SQLite database — size
  `evebox.persistence.size` with both in mind.
- On a quiet firewall, EveBox logs a missing-spool warning roughly every 15
  seconds until the first event arrives. It is harmless; it just looks alarming
  in `kubectl logs`.
- EveBox runs as UID 0 — the upstream `jasonish/evebox` image has no non-root
  user. It will not schedule in a namespace enforcing the `restricted` Pod
  Security Standard; use `baseline` or `privileged`.
- EveBox exposes no Prometheus metrics endpoint, so this chart ships no
  ServiceMonitor or alert rules for it. Triage happens in the EveBox UI; pod
  health is covered by ordinary Kubernetes Deployment status.

## NetFlow traffic analytics

With `akvorado.enabled: true` the chart deploys the Akvorado pipeline
(orchestrator, inlet, outlet, console), a Redpanda broker, and a vendored
single-node ClickHouse.

- The inlet's NetFlow Service is the target for the firewall's NetFlow export
  (`akvorado.netflow.serviceType`, `LoadBalancer` by default).
- It uses `externalTrafficPolicy: Local` to preserve OPNsense's real source IP,
  since Akvorado attributes flows by source address. This requires a
  `LoadBalancer` implementation that preserves client IPs — true for MetalLB
  and most cloud load balancers.
- GeoIP data for the destination-country panel comes from
  [DB-IP Lite](https://db-ip.com/db/lite.php): free, no account or license key,
  refreshed monthly by an in-chart CronJob. Attribution: this product includes
  GeoLite2 data created by DB-IP, distributed under the
  [CC BY 4.0 license](https://creativecommons.org/licenses/by/4.0/).
- The Akvorado console and the traffic dashboard need a Grafana **ClickHouse**
  datasource pointed at the `<release>-clickhouse` Service on port `9000`. This
  chart does not provision Grafana datasources, so add one through your Grafana
  provisioning of choice.
- ClickHouse's default user has no password. That is acceptable because the
  Service is a plain `ClusterIP` never exposed outside the cluster, but worth
  knowing before running this chart on a shared or multi-tenant cluster.
- Akvorado's four workloads run as UID 0 — the upstream
  `quay.io/akvorado/akvorado` image has no non-root user. Like EveBox, they will
  not schedule under a `restricted` Pod Security Standard namespace.

## Installation

```bash
helm repo add redpanda https://charts.redpanda.com
helm dependency build .

helm install opnsense-observability . \
  --namespace monitoring --create-namespace \
  --values my-values.yaml
```

Start from one of the shipped examples:

- `examples/minimal-values.yaml` — opnsense-exporter, dashboards, and alerts.
- `examples/full-values.yaml` — everything, including Akvorado NetFlow
  analytics and EveBox IDS triage.

## Values reference

| Key | Description |
| --- | --- |
| `opnsenseExporter.enabled` | Deploy opnsense-exporter, which polls the OPNsense REST API. |
| `opnsenseExporter.opnsense.address` | OPNsense firewall address (required). |
| `opnsenseExporter.opnsense.protocol` | `https` or `http` for the REST API. |
| `opnsenseExporter.opnsense.instanceLabel` | Value of the `opnsense_instance` label the exporter applies to its `opnsense_*` metrics. It is the value the health dashboard's **OPNsense Instance** picker selects. |
| `opnsenseExporter.opnsense.insecureSkipVerify` | Skip TLS verification of the firewall's API certificate. |
| `opnsenseExporter.opnsense.apiKeySecretRef` | Secret reference holding the read-only API key. |
| `opnsenseExporter.opnsense.apiSecretSecretRef` | Secret reference holding the read-only API secret. |
| `dashboards.enabled` | Render the Grafana dashboard ConfigMaps. |
| `dashboards.folder` | Grafana folder the dashboards are filed under. |
| `alerts.enabled` | Render the `PrometheusRule`. |
| `alerts.firmwareUpdateAvailable` | Alert when OPNsense reports pending package updates. |
| `alerts.gatewayDown` | Alert when any gateway's status is not Online, monitor-only entries included. |
| `alerts.highPacketLoss` | Alert above `thresholdPercent` packet loss on a gateway. |
| `alerts.highLatency` | Alert above `thresholdMs` round-trip time on a gateway. |
| `alerts.akvoradoPipelineLag` | Alert when the Akvorado inlet is receiving flows but the outlet has stopped consuming. |
| `serviceMonitor.enabled` | Render `ServiceMonitor` objects for the chart's own workloads. |
| `serviceMonitor.namespace` | Namespace for the ServiceMonitors; defaults to the release namespace. |
| `serviceMonitor.labels` | Labels matching the cluster Prometheus's `serviceMonitorSelector`. |
| `serviceMonitor.interval` | Scrape interval. |
| `akvorado.enabled` | Turn on the NetFlow traffic-analytics pipeline (Redpanda + ClickHouse + Akvorado orchestrator/inlet/outlet/console). Default `false`. |
| `akvorado.netflow.listenPort` | UDP port the inlet listens on for NetFlow records. |
| `akvorado.netflow.serviceType` | Service type for the inlet's NetFlow listener; `LoadBalancer` so OPNsense on the LAN can reach it. |
| `akvorado.kafka.brokers` | External Kafka broker list; empty (default) uses the bundled Redpanda's internal listener. |
| `akvorado.clickhouse.persistence.size` | PVC size for the vendored single-node ClickHouse StatefulSet. |
| `akvorado.geoip.enabled` | Auto-download GeoIP databases via an in-chart CronJob. |
| `akvorado.geoip.source` | `dbip-lite` (no account needed) or `maxmind`. |
| `akvorado.geoip.updateSchedule` | Cron schedule for the GeoIP refresh job. |
| `akvorado.console.ingress.enabled` | Expose the Akvorado console via Ingress. |
| `evebox.enabled` | Deploy EveBox plus its Vector syslog sidecar for Suricata IDS alert triage. Default `false`. |
| `evebox.service.type` | Service type for the EveBox **web UI**. Keep `ClusterIP` — the UI runs without authentication. |
| `evebox.service.port` | Port the EveBox web UI listens on. |
| `evebox.syslog.service.type` | Service type for the syslog listener. Defaults to `ClusterIP`; set it to `LoadBalancer` so the firewall can ship EVE JSON to it. |
| `evebox.syslog.service.port` | TCP port the Vector sidecar accepts RFC5424 syslog on, and the port the firewall's logging target uses. |
| `evebox.syslog.maxMessageBytes` | Maximum accepted syslog message size. EVE lines carrying packet payloads are large, so this is well above Vector's default. |
| `evebox.ingress.enabled` | Expose the EveBox **web UI** via Ingress. Does not carry syslog. |
| `evebox.persistence.size` | PVC size, shared by the SQLite event database and the unrotated EVE spool file. |
| `extraObjects` | Escape hatch for arbitrary extra manifests rendered alongside this chart (see below). |

See `values.yaml` for the full set of keys, including image, resource, and
passthrough values for the `redpanda` subchart.

## Scraping os-node_exporter on the firewall

This chart has no built-in way to scrape `os-node_exporter` running on the
OPNsense firewall itself — it is an out-of-cluster target. Use the generic
`extraObjects` escape hatch to add a headless Service plus matching Endpoints
pointing at the firewall's LAN IP and port `9100`, so your cluster Prometheus
can scrape it like any other target:

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

Add a `ServiceMonitor` (or point your Prometheus's existing selector at this
Service) to complete the scrape config. Each `extraObjects` entry is rendered
with Helm's `tpl`, so `.Release` and `.Values` are usable inside it.

## License

MIT — see `LICENSE`.
