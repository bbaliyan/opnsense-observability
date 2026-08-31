# opnsense-observability — Design Spec

Status: approved for implementation planning.
Supersedes the observability tiers (InfluxDB, Elasticsearch/Graylog/Mongo,
os-telegraf) described in `iac-others/opnsense/opnsense-homelab-spec.md` §3 —
see that file's superseded-section note for the pointer back here.

**Revision 2026-08-30:** the original all-Loki plan for Suricata/firewall
logs is revised — see §2/§3/§6. Firewall/pf logs still go to Loki (they're
structured and filter-friendly; Loki's weak point is unstructured full-text
search, which doesn't apply here). Suricata IDS alerts specifically now go
to **EveBox** (SQLite-backed) instead — a purpose-built, actively
maintained Suricata alert-triage tool (maintained by a core Suricata/OISF
contributor), not a DIY LogQL dashboard, and much lighter than the
Elasticsearch+Graylog+MongoDB stack this design already rejected. Decided
after the user pushed back on the original Loki-only plan specifically for
GeoIP enrichment and search quality on IDS alerts — see §2/§3/§6 for the
resolution.

---

## 1. Goal

A public, reusable Helm chart that gives a K8s-homelab operator (starting
with the author, but designed for other GitHub users too) deep visibility
into an OPNsense firewall and their home internet: system/service health,
firmware-update actionability, gateway and external latency/jitter with
real outage detection, per-client/global traffic analytics (where traffic
goes, who's generating it), and IDS alert triage — with **near-zero
required changes to OPNsense**, almost entirely enabling existing built-in
features (REST API, NetFlow export, an official plugin), with one
deliberate, documented exception (the EveBox Agent, §6 step 6b) — and
dashboards good enough to be the chart's main selling point, not an
afterthought.

Non-goals: this chart does not deploy Prometheus, Grafana, Alertmanager, or
Loki — it assumes a kube-prometheus-stack-compatible Prometheus Operator
(ServiceMonitor/PrometheusRule CRDs) and a Grafana with the sidecar
dashboard-ConfigMap convention already exist in the target cluster, which is
the dominant K8s observability baseline today. It does not build a custom
web frontend — visualization is 100% curated Grafana dashboards.

---

## 2. Architecture

```
OPNsense (config-only changes, no new agents)
 ├─ REST API (existing, read-only API key)         ──┐
 ├─ dpinger gateway monitor (existing)                ├──→ opnsense-exporter (in-cluster Deployment) ──→ Prometheus (ServiceMonitor)
 ├─ os-node_exporter plugin (user installs, doc'd)   ──→ scraped directly ──→ Prometheus (ServiceMonitor)
 ├─ NetFlow/IPFIX export (built-in, user points it
 │  at the chart's akvorado-inlet Service)            ──→ Akvorado inlet
 ├─ pf/firewall logs → syslog                         ──→ existing Alloy/Loki, with Alloy's native stage.geoip
 │                                                          enriching source IPs before they land in Loki (config, not custom code)
 └─ Suricata EVE JSON → EveBox Agent (small binary,
    manually installed on OPNsense — the one non-plugin
    piece in this design, see §6 step 6)               ──→ EveBox server (in-cluster, SQLite backend)

In-cluster, independent of OPNsense:
 blackbox-exporter → ICMP probes, 5–15s interval → 1.1.1.1, 8.8.8.8, OPNsense WAN gateway IP → Prometheus
 (cluster-side vantage point: pod → LAN → OPNsense → WAN → target)

Dual vantage point for 1.1.1.1/8.8.8.8 specifically (see §2a) — OPNsense
itself also monitors these via two monitor-only dpinger gateway entries,
read by opnsense-exporter over the same REST API path as everything else.

Akvorado pipeline (in-cluster, 4 components — revised 2026-08-30, see §3):
orchestrator (owns Kafka topic + ClickHouse schema, serves shared config to
the other three over HTTP) + inlet (receives NetFlow/IPFIX, produces to
Redpanda unparsed) → Redpanda (Kafka-API compatible) → outlet (consumes,
enriches with GeoIP, writes to ClickHouse) → ClickHouse (vendored
single-node StatefulSet) → {Akvorado console, Grafana via ClickHouse
datasource}

Rendering: Prometheus ServiceMonitors + PrometheusRules, Grafana dashboards as
sidecar-loaded ConfigMaps (grafana_dashboard: "1"). Alerts route through
whichever Alertmanager already exists — this chart adds rules, not a new
Alertmanager.
```

### 2a. Dual vantage point for internet-connectivity probing

A single blackbox-exporter probe from inside the cluster can't distinguish
"the WAN is actually down" from "the pod→OPNsense path is flaky" — both
show up identically as a failed probe. Fix: probe 1.1.1.1 and 8.8.8.8 from
**two independent vantage points** and let the dashboard show both:

1. **Cluster-side** (blackbox-exporter, existing plan) — `probe_success`/
   `probe_duration_seconds` per target, labeled `vantage="cluster"`.
2. **OPNsense-side** — two extra gateway entries under System → Gateways,
   each with routing/failover disabled and "Monitor IP" set to 1.1.1.1 and
   8.8.8.8 respectively (a standard OPNsense pattern: dpinger monitors any
   IP you put in that field, independent of the gateway's actual next-hop).
   `opnsense-exporter` already scrapes gateway/dpinger status via the REST
   API, so these appear as ordinary metrics — `vantage="opnsense"` — with no
   new agent or collection path.

Dashboard reads it as a simple truth table on the connectivity dashboard
(see §5): both vantage points down → real WAN/ISP outage; OPNsense-side up
but cluster-side down → problem is between the cluster and OPNsense
(flaky LAN link, switch, or the cluster node itself), not the internet
connection. This is the chart's answer to "is my internet actually down."

**Why this stays zero/near-zero impact on OPNsense:** every OPNsense-side
capability used (REST API, dpinger, NetFlow export, node_exporter plugin)
is a native, already-shipping feature the user flips on — nothing custom is
installed except the one official FreeBSD-ported plugin, which is a tiny
pull-based agent maintained by the OPNsense plugin ecosystem itself, not a
custom binary this project ships.

---

## 3. Chart composition

Umbrella chart with subchart dependencies where a good upstream exists;
vendored templates only where nothing maintained exists.

| Component | Source | Why |
|---|---|---|
| `blackbox-exporter` | dependency: `prometheus-community/prometheus-blackbox-exporter` | Official, actively maintained, no reason to reinvent |
| `redpanda` | dependency: Redpanda Data's official chart | Kafka-API-compatible broker for Akvorado inlet→outlet, no JVM/ZooKeeper — current lightweight standard |
| `clickhouse` | vendored single-node StatefulSet + PVC | **Revised 2026-08-30 (Plan 2 kickoff):** matches Akvorado's own reference deployment (a single plain ClickHouse container, no operator/cluster) — Altinity's `clickhouse-operator` was the original pick but is a cluster-scoped operator+CRD built for multi-node HA, which is out of proportion for one homelab firewall's flow data and inconsistent with this chart's own non-goal of not bundling shared cluster-wide operators (same reasoning as not bundling Prometheus/Grafana/Loki) |
| `akvorado` (orchestrator, inlet, outlet, console) | vendored templates (Deployment/Service/ConfigMap ×4) | **Revised 2026-08-30:** verified against the real upstream repo (`github.com/akvorado/akvorado`) — Akvorado 2.0 has four components, not three as the original spec assumed. The **orchestrator** owns Kafka topic + ClickHouse schema management and serves shared config to inlet/outlet/console over HTTP; it did not appear in the original architecture diagram. No maintained upstream Helm chart exists for any of the four (verified) |
| `evebox` (server, SQLite backend) | vendored templates (Deployment/Service/PVC) | No maintained upstream chart exists (verified 2026-08-30). Purpose-built Suricata alert-triage UI (native GeoIP, structured search) — replaces the rejected Elasticsearch+Graylog+MongoDB tier for IDS alerts specifically, while pf/firewall logs stay on Loki (see revision note at top of doc) |
| `opnsense-exporter` | vendored templates (Deployment/Service, Secret for API creds) | No maintained upstream chart exists (verified) |
| Grafana dashboards | vendored ConfigMaps, `grafana_dashboard: "1"` label | Curated/redesigned, not raw-imported community JSON (see §5) |
| PrometheusRules | vendored | Firmware update available, gateway down, high loss/latency, interface errors, Akvorado pipeline lag |

Every top-level component gated by `<component>.enabled` in `values.yaml` so
a user can run e.g. exporter+blackbox+dashboards only, without the
Redpanda/ClickHouse footprint, if they don't want netflow analytics.

---

## 4. values.yaml — key shape

```yaml
opnsenseExporter:
  enabled: true
  opnsense:
    apiUrl: ""                # e.g. https://192.168.1.1
    apiKeySecretRef: {name: "", key: "api-key"}
    apiSecretSecretRef: {name: "", key: "api-secret"}
    insecureSkipVerify: false
  # Names of the monitor-only dpinger gateways (see §2a / §6 step 3) that
  # correspond to the blackbox targets below, so dashboards can pair up
  # "vantage=opnsense" and "vantage=cluster" series for the same target.
  connectivityGatewayNames:
    cloudflare: "MONITOR_CLOUDFLARE"
    google: "MONITOR_GOOGLE"

blackboxExporter:
  enabled: true
  targets:
    - address: 1.1.1.1
      name: cloudflare
    - address: 8.8.8.8
      name: google
    - address: ""             # OPNsense WAN gateway IP, user-supplied
      name: wan-gateway
  scrapeInterval: 10s         # 5-15s band; not the old 5m default

akvorado:
  enabled: true
  netflow:
    listenPort: 2055
    serviceType: LoadBalancer  # so OPNsense on the LAN side can reach it
  geoip:
    source: dbip-lite          # dbip-lite (default, no account) | maxmind | custom
    updateSchedule: "0 6 1 * *" # monthly CronJob re-download (DB-IP Lite ships monthly)
  console:
    ingress: {enabled: false}  # off by default; user opts in for their own host/TLS
  redpanda: {...}               # sizing/replica passthrough
  clickhouse: {...}             # sizing/retention passthrough

evebox:
  enabled: true
  backend: sqlite                # sqlite (default, no reporting) | elasticsearch
  persistence:
    size: 5Gi                    # SQLite data volume; retention tuned separately below
  retentionDays: 7                # SQLite backend default; ignored if backend=elasticsearch
  # The EveBox Agent runs on OPNsense itself (§6 step 6), not in-cluster —
  # this just needs a reachable Service/Ingress for it to ship events to.
  agentIngestPort: 5636

dashboards:
  enabled: true
  folder: "OPNsense"

alerts:
  enabled: true
  firmwareUpdateAvailable: {enabled: true, severity: warning}
  gatewayDown: {enabled: true, severity: critical}
  highPacketLoss: {enabled: true, thresholdPercent: 5, severity: warning}
  highLatency: {enabled: true, thresholdMs: 150, severity: warning}

serviceMonitor:
  enabled: true
  namespace: ""                # defaults to release namespace
  labels: {}                   # match the cluster's Prometheus Operator selector
```

Two example values files ship in `examples/`: `minimal-values.yaml`
(exporter + blackbox + dashboards, no Akvorado) and `full-values.yaml`
(everything on).

---

## 5. Dashboards — the flagship, designed not imported

Applying the categorical/sequential/status color rules and mark-selection
method from the project's dataviz standard (fixed hue order for identity,
single-hue ramps for magnitude, reserved status colors for state, no
dual-axis panels, legends always present at 2+ series) to Grafana's panel
types specifically:

- **Connectivity / outage dashboard** — two stacked **state-timeline**
  panels (green/amber/red bars over time) as the primary "was the internet
  actually down" view: one row per vantage point (`cluster` via
  blackbox-exporter, `opnsense` via the monitor-only dpinger gateways, §2a),
  same time axis, so a real WAN outage reads as both rows red and a
  LAN/cluster-path issue reads as only the cluster row red — the direct
  fix for "5-minute plots can't show a real dropout, and I can't tell
  where the problem is." Latency and jitter get their own **time-series**
  panels below it (never crammed onto the state-timeline itself), one hue
  per probe target in a fixed order (Cloudflare / Google / gateway),
  consistent across both vantage points, never re-cycled if a target is
  added/removed. Packet loss gets a single-hue sequential heatmap by
  hour-of-day/day-of-week — the "when does my internet get bad" view.
- **OPNsense health dashboard** — stat tiles (CPU/mem/disk/uptime) using
  status-color thresholds only at the tile, never on the trend line beneath
  it; firmware-update-available renders as a persistent banner-style stat
  panel in the warning color, not buried in a table. Its Unbound panel is
  scoped to what `opnsense-exporter` actually exposes — DNSSEC
  secure/bogus answer counts and uptime only (verified 2026-08-30, §6 step
  1) — not the full query-type/RCODE/histogram breakdown that extended
  statistics makes available at the OPNsense level; that richer data isn't
  reachable through this exporter.
- **Traffic/netflow dashboard (Akvorado-backed)** — geomap for
  destination-country traffic (sequential single-hue by volume, not a
  rainbow), a top-talkers table (per source IP/DHCP hostname), and a
  protocol/ASN breakdown as small multiples rather than one overloaded
  stacked chart. One axis per chart throughout — Mbps and connection-count
  never share a panel.
- Every dashboard: consistent variable-driven target/interface picker at
  the top, dark-mode-first (matches Grafana's own default and most
  homelab setups), a shared color/legend convention across all three
  dashboards so a series always means the same thing everywhere.

This work happens chart-side as hand-built dashboard JSON (or `grafonnet`
if the implementation plan chooses it for maintainability), not a
reskin of the community dashboards referenced during research (IDs 21113 /
9291) — those inform panel *content* only, not visual design.

---

## 6. OPNsense-side prerequisites (documented, not automated by the chart)

Checklist below is grounded against a real exported `config.xml` reviewed
2026-08-30 (author's sandbox instance) — each item states the config's
actual prior state so the README checklist doesn't read as generic
guesswork.

1. **Create a dedicated, least-privilege API user for `opnsense-exporter`
   — DONE, verified 2026-08-30 end-to-end against a live exporter run.**
   Prior state: zero API keys exist for any user, including root. The API
   is unavoidably authenticated — OPNsense's REST API has no anonymous
   mode, regardless of source IP; this is the one piece of the chart that
   genuinely cannot be made keyless (see design discussion 2026-08-30).
   Exact steps taken:

   a. System → Access → Groups → **+** → create group
      `opnsense-exporter-ro`, description `Read-only, API-only —
      opnsense-observability chart`. In its Assigned Privileges, use the
      search/filter box and tick entries under **Status**, **Diagnostics**,
      **Reporting**, **Services** (Unbound DNS, plus whichever of
      OpenVPN/IPsec/WireGuard/Kea DHCP are in use), and **System** →
      Firmware + Gateways. Do **not** grant anything under System → Access
      or a full-admin privilege. (Exact checkbox wording can shift between
      OPNsense releases — use the search box rather than hunting a fixed
      menu tree.)
   b. System → Access → Users → **+** → username `svc-opnsense-exporter`,
      password = any long random string (never used — this account
      authenticates via API key only), Group Membership = only
      `opnsense-exporter-ro`. Save.
   c. Open that user again → **API keys** section → **+** → OPNsense
      generates and downloads a key/secret pair immediately — shown once
      only; losing it means regenerating (invalidates the old one), not
      retrieving it again. This becomes the k8s Secret referenced by
      `opnsenseExporter.opnsense.apiKeySecretRef`/`apiSecretSecretRef`
      (§4) — never commit the raw key/secret to git.

   **Verification (full end-to-end, no Kubernetes needed):**
   ```
   # 1. Auth-only sanity check
   curl -sk -u "<api-key>:<api-secret>" https://192.168.1.1/api/core/firmware/status | jq .
   # 200 + JSON = good; 401 = bad key/secret; 403 = key valid but group is missing a privilege

   # 2. Full test: run the actual exporter locally via Docker, exercising
   # the exact code path the chart will run later
   docker run --rm -p 8080:8080 \
     ghcr.io/athennamind/opnsense-exporter:latest \
     --opnsense.protocol=https \
     --opnsense.address=192.168.1.1 \
     --opnsense.api-key="<api-key>" \
     --opnsense.api-secret="<api-secret>" \
     --opnsense.insecure \
     --exporter.instance-label=opnsense-sandbox

   curl -s http://localhost:8080/metrics | grep -E "opnsense_(firmware|gateway|service|unbound)"
   ```
   Confirmed-good result (this exact run, 2026-08-30): `opnsense_firmware_*`
   populated (`new_packages=0`, `upgrade_packages=0`, `needs_reboot=0` —
   the metrics the firmware-update-available alert rule keys off);
   `opnsense_gateways_*` showing `MONITOR_CLOUDFLARE`/`MONITOR_GOOGLE`
   alongside `WAN_DHCP` with real `status=1` (Online),
   `rtt_milliseconds`/`rttd_milliseconds` — confirms §2a's dual-vantage
   design works end to end; `opnsense_services_status` showing 17 running
   incl. three distinct `dpinger` processes (one per gateway, plus "Gateway
   Watcher") and `telegraf agent` still running (expected — not
   decommissioned yet, step 7); `opnsense_unbound_dns_*` populated,
   confirming extended statistics (step 3) actually reaches this exporter.

   **Known limitation surfaced by this test:** the exporter's Unbound
   metric surface is much narrower than the raw data confirmed via
   `unbound-control` in step 3 — only `answer_bogus_total`,
   `answer_secure_total`, and `uptime_seconds` make it through; no
   query-type/RCODE/histogram breakdown. This is an upstream-project
   limitation, not a misconfiguration — the OPNsense health dashboard's
   Unbound panel (§5) should be scoped to what's actually exposed here,
   not the full extended-statistics data model.
2. **Install and configure the `os-node_exporter` plugin — DONE, verified
   2026-08-30.** Prior state: not installed — no config block for it
   existed at all.

   a. Firmware → Plugins → search `os-node_exporter` → install.
   b. Services → Prometheus Exporter → confirm/set:
      - Enabled: checked
      - Listen Address: `0.0.0.0` (all interfaces — fine since this
        endpoint is unauthenticated by design, same trust model as any
        node_exporter; rely on the LAN-only firewall posture, not
        interface binding, to keep it internal)
      - Listen Port: `9100` (default, left as-is)
      - Collectors: leave **all** enabled (CPU, Execution, Filesystem,
        Load Average, Memory, Network Interface, Current Time, Device,
        Interrupts, NTP, ZFS) — none are expensive at single-firewall
        scale. Interrupts is worth keeping specifically because WAN
        (`ix0`) runs on X540 passthrough (see `opnsense-homelab-spec.md`
        §3 update) — useful if IRQ affinity ever needs diagnosing. ZFS is
        genuinely relevant here, not a no-op: this instance's root
        filesystem **is** ZFS (`zroot` pool, confirmed by the test below)
        — an earlier assumption in this project that OPNsense defaults to
        UFS-on-root was wrong for this instance.
      - Save.

   **Verification:**
   ```
   curl -s http://192.168.1.1:9100/metrics | grep -E "^node_(cpu|memory|filesystem|network|disk)" | head -40
   ```
   Confirmed-good result (this exact run, 2026-08-30): per-core
   `node_cpu_seconds_total` (modes idle/interrupt/nice/system/user) for all
   4 vCPUs; `node_filesystem_avail_bytes` across the full `zroot/*` ZFS
   dataset tree plus the `efiboot0` ESP — real data, no auth required. No
   firewall rule needed for this instance — the curl succeeded directly,
   unlike the SSH case in step 3, where the WAN sits on a different
   physical NIC namespace but LAN-side rules were already permissive
   enough here.
3. **Enable Unbound extended statistics — DONE, verified 2026-08-30.** Prior
   state: off. **Exact location** (this is easy to get wrong — it is not on
   the General page): Services → Unbound DNS → **Advanced** → *Logging
   Settings* section → check **Extended Statistics** → Apply. The General
   page has no statistics toggle at all; a separate "Statistics" sidebar
   item under Unbound DNS is a display-only page — it shows only basic
   counters (recursion time, cache hits/misses, queue stats) regardless of
   whether extended statistics is on, so it **cannot** be used to verify
   this setting.

   **Verification (does not need opnsense-exporter deployed):** SSH is off
   by default on OPNsense — enable it first via System → Settings →
   Administration → Secure Shell (add an authorized key under System →
   Access → Users → *user* → Authorized keys before switching to key-only
   auth, or you'll lock yourself out). Then, on the box:
   ```
   unbound-control -c /var/unbound/unbound.conf stats_noreset
   ```
   (the `-c /var/unbound/unbound.conf` is required — bare `unbound-control`
   reads the wrong, non-OPNsense-managed default config path and fails with
   `control-enable is 'no'` / connection refused, even though extended
   statistics is genuinely on). Confirmed-on output includes
   `num.query.type.A`/`AAAA`, `num.query.class.IN`, `num.answer.rcode.*`,
   and a full `histogram.*` bucket series — this is the exact data
   `opnsense-exporter`'s DNS panels read from later, so a good result here
   is a real end-to-end confirmation, not just "the checkbox was clicked."
4. **Add two monitor-only gateways for the dual-vantage connectivity probe**
   (§2a) — **DONE, verified 2026-08-30, both showing live RTT/loss on the
   Gateways list.** Prior state: **zero gateways defined in config at
   all** — WAN is plain DHCP with a live auto-managed gateway (`WAN_DHCP`,
   dynamic, priority 254) that already appears in System → Gateways →
   Configuration. Exact steps taken, replicable as-is:

   a. System → Gateways → Configuration → `+` (New).
   b. Fill in exactly these fields, leave everything else at its form
      default:

      | Field | Cloudflare entry | Google entry | Why |
      |---|---|---|---|
      | Name | `MONITOR_CLOUDFLARE` | `MONITOR_GOOGLE` | Must exactly match `opnsenseExporter.connectivityGatewayNames` in values.yaml |
      | Interface | WAN | WAN | Same physical path as real WAN gateway |
      | Address Family | IPv4 | IPv4 | |
      | Priority | 255 (form default, leave as-is) | 255 | Lowest preference — never wins as a default route even by accident |
      | **IP Address** | `1.1.1.1` | `8.8.8.8` | The real target, set directly — deliberately **not** the WAN's current DHCP-assigned gateway IP, which is dynamic and would go stale the moment the ISP reassigns it (confirmed with user 2026-08-30 — an earlier draft of this checklist got this wrong) |
      | **Far Gateway** | **checked** | **checked** | Required — `1.1.1.1`/`8.8.8.8` are off-link (not on the WAN's local subnet); this tells OPNsense not to expect ARP for them and to route via WAN's existing default route instead. Leaving this unchecked is the most likely mistake when replicating this — the form accepts an off-link `IP Address` either way but monitoring won't work correctly without it. |
      | Disable Gateway Monitoring | unchecked | unchecked | The entire point is dpinger monitoring it |
      | Disable Host Route | unchecked | unchecked | An earlier draft of this checklist said to check this — wrong: checking it can prevent the route needed to reach the far gateway at all. Leave unchecked. |
      | Monitor IP | leave blank | leave blank | With Far Gateway set and no override, dpinger monitors `IP Address` itself — no need to duplicate the value here |
      | Description | `Monitor-only: opnsense-observability latency/jitter probe` | same | |

   c. Save, repeat for the second entry, then confirm both rows appear on
      the Gateways list with live RTT/RTTd/Loss columns populating within a
      few seconds — that's the verification signal, no service restart
      needed.
   d. Do **not** select either new gateway as any interface's default
      gateway and do **not** add it to a Gateway Group used by firewall
      rules — leaving both alone is what keeps this monitor-only (no
      routing impact).
5. **Enable NetFlow/IPFIX export.** Prior state: plugin present but fully
   inactive (`collect.enable = 0`, no interfaces, no targets; version
   already correctly set to `v9`). Reporting → Netflow: enable capture,
   select WAN (and LAN if internal-to-internal visibility is wanted), set
   target = the chart's `akvorado-inlet` Service address, port `2055`, once
   that Service exists post-install.
6. **Ship logs to their two destinations — pf/firewall logs to Loki,
   Suricata IDS alerts to EveBox.** (Revised 2026-08-30 — see the revision
   note at the top of this doc.) Both only relevant once Suricata is
   actually turned on; it's currently installed but fully disabled, which
   matches the separate, not-yet-built IDS decision in
   `opnsense-homelab-spec.md` §3 — nothing to do here until that happens.

   a. **pf/firewall logs → Loki.** Prior state: syslog is enabled locally
      but has **zero remote destinations** configured. System → Settings →
      Logging / Syslog: add a destination pointed at the existing
      in-cluster Alloy/Loki syslog receiver. Alloy's native `stage.geoip`
      block enriches source IPs with country/city/ASN before the line
      lands in Loki — this is Alloy config, not custom code, and answers
      the GeoIP concern for this log stream.
   b. **Suricata EVE JSON → EveBox.** Prior state: N/A, new destination.
      Turn on EVE JSON logging in the IDS plugin (Services → Intrusion
      Detection → Administration → enable EVE JSON output). Install the
      **EveBox Agent** on OPNsense — a small binary, *not* an OPNsense
      plugin (no entry in Firmware → Plugins for it), the one deliberate
      exception to "every OPNsense-side piece is a native, already-shipping
      feature" in this design (decided 2026-08-30 after evaluating an
      Alloy-dual-shipping alternative that would have avoided this, but
      was unverified — see design discussion). Configure the Agent to tail
      the EVE JSON file and ship to the chart's EveBox server Service
      (`evebox.agentIngestPort`, §4). EveBox's SQLite backend needs no
      Elasticsearch — confirmed via EveBox's own docs, which state the
      Agent (or direct server file reads) works with either backend.
7. **Decommission `os-telegraf` — last step, only after validating the
   above.** Prior state: active and doing real work (`prometheus_client` on
   :9273; ping input already covering 1.1.1.1/8.8.8.8 at count=5; cpu/disk/
   mem/network/unbound/system inputs; 10s interval). Once opnsense-exporter,
   the `os-node_exporter` plugin, and the two monitor-gateways from step 4
   are confirmed populating the same data in Prometheus/Grafana, disable
   Telegraf (Services → Telegraf → General) and uninstall `os-telegraf`
   (Firmware → Plugins). Don't remove it before the replacement is proven
   live — it's the only working connectivity/system-metrics path until then.

The chart's README documents each with exact GUI paths; none of this is
Terraform/Ansible-automated by the chart itself, since it targets any
OPNsense instance, not just the author's IaC-managed one.

---

## 7. Distribution & repo

- Public GitHub repo `opnsense-observability` (this repo).
- Published as an OCI Helm chart to GHCR
  (`oci://ghcr.io/<user>/charts/opnsense-observability`) — current
  Helm-standard distribution, not gh-pages/index.yaml.
- GitHub Actions: `helm lint` + `ct lint-and-install` against `kind` on PR;
  `helm push` to GHCR on tag; `helm-docs` regenerates the values reference
  on every values.yaml change.
- README: prerequisites (§6), quickstart, full values reference, screenshots
  of the three flagship dashboards.
- Semver releases + CHANGELOG.
- No AI/Claude attribution in commit messages or PR descriptions, ever, for
  this repo — a fixed project convention regardless of tooling used to help
  author it.

---

## 8. Testing

- `helm lint` and `ct lint-and-install` (chart-testing) against a `kind`
  cluster in CI — installs with `examples/minimal-values.yaml` and
  `examples/full-values.yaml`, asserts all pods reach Ready.
- Dashboard JSON validated for schema correctness (`grafana` dashboard
  JSON schema check) in CI, not just eyeballed.
- No live OPNsense instance in CI — opnsense-exporter/blackbox-exporter
  behavior against a real API is validated manually against the author's
  sandbox VM before each tagged release, noted in the release checklist.

---

## 9. Open items — resolved 2026-08-30 (Plan 2 kickoff)

- [x] **GeoIP source default: DB-IP Lite** (`dbip-country-lite.mmdb` +
      `dbip-asn-lite.mmdb`). No account or license key — direct HTTPS
      download, CC BY 4.0 (attribution-only, documented in the README, not
      a runtime credential). Rejected MaxMind GeoLite2 and IPinfo Lite for
      the default specifically because both require an account/token even
      though free, which fails the "completely OSS, zero signup" bar the
      user set. Chart runs a monthly CronJob (`akvorado.geoip.updateSchedule`,
      default `0 6 1 * *`) that re-downloads both `.mmdb` files into a
      shared volume the inlet mounts read-only — DB-IP republishes monthly,
      so a one-time init download would silently go stale. `akvorado.geoip.source:
      maxmind` remains supported for users who already have a MaxMind
      account and prefer its data, via `licenseKeySecretRef`, but is not
      the default.
- [x] **Akvorado console Ingress: optional, disabled by default**
      (`akvorado.console.ingress.enabled: false`). Chart ships the
      host/TLS/annotations block so users who want it don't hand-roll a
      separate Ingress resource, but a zero-config install stays untouched.
- [x] **Dashboard authoring: hand-authored JSON**, consistent with Plan 1's
      two existing dashboards — avoids introducing a second toolchain
      (grafonnet/jsonnet build step) partway through the project.
