# okd-status

A single-file, live **tmux dashboard for OpenShift / OKD clusters**. Run it,
and a tmux session fills your terminal with auto-refreshing, colour-coded panes
showing what your cluster is doing right now — nodes, operators, machine config
pools, non-running pods, and a live event stream.

Everything is driven by `oc` against your current kube context. No agent, no
server, no config required — just a shell script.

```
┌────────────────────────────┬──────────────────────────────────┐
│ CLUSTER                    │ NODE USAGE (cpu / mem)            │
│  ● version 4.x.y           │   ● master-0   1200m 34%  9Gi 60% │
│  ● nodes 6/6 ready         │   ● worker-1    800m 22%  6Gi 41% │
│  ● operators 33 available  │ ALERTS (0 firing)                 │
│  ● machine config pools ok │   ● none (warning/critical)       │
│  ● alerts none firing      │                                   │
│  (optional SERVICES/HOSTS) │                                   │
├────────────────────────────┴──────────────────────────────────┤
│ NODES   6 Ready · 0 NotReady    all 6 nodes Ready              │
│ MACHINE CONFIG POOLS                                           │
│ OPERATORS  version: 4.x.y   all 33 operators green             │
│ PODS (non-running)   no non-running pods                       │
│ LIVE EVENTS  ...                                               │
└────────────────────────────────────────────────────────────────┘
```

## What each pane shows

| Pane | Refresh | Contents |
|------|--------:|----------|
| **cluster summary** | 30s | cluster version, nodes ready, operators degraded/progressing, MCP status, firing-alert roll-up (+ optional service & host checks) |
| **node usage** | 45s | `oc adm top nodes` and firing Prometheus alerts (warning/critical, Watchdog dropped) |
| **nodes** | 10s | `oc get nodes` — only **non-green** nodes (NotReady / cordoned / unknown); banner tallies Ready / NotReady / SchedulingDisabled |
| **machine config pools** | 20s | `oc get mcp`, highlighting updating/degraded pools |
| **operators** | 30s | cluster version + `oc get co`, hiding healthy operators so only anomalies show |
| **pods** | 15s | `oc get pods -A` filtered to non-running (CrashLoop, Pending, OOMKill, …) |
| **events** | live | `oc get events -w -A`, colour-coded, auto-reconnecting |

Panes self-resize to their content, so the dashboard stays compact when the
cluster is healthy and expands when something needs attention.

## Requirements

- `oc` (OpenShift CLI) logged in to a cluster — or `kubectl` symlinked to `oc`
- `tmux`
- `python3` (alert parsing)
- `awk`, `curl`, `ssh` (the last two only if you use the optional config)

The firing-alerts section execs into `prometheus-k8s-0` in the
`openshift-monitoring` namespace, so it needs a cluster with the built-in
OpenShift monitoring stack and permission to `exec` there. If that's
unavailable it just prints "unavailable" — the rest of the dashboard still
works.

## Usage

```bash
git clone https://github.com/<you>/okd-status.git
cd okd-status
./okd-status.sh
```

Point it at any cluster by exporting `KUBECONFIG` first, or just rely on your
current `oc login` context.

Replace the bottom **events** pane with any log/follow command:

```bash
./okd-status.sh "oc logs -f -n openshift-machine-config-operator deploy/machine-config-operator"
```

The command is wrapped in an auto-reconnect loop, so it survives watch
timeouts and cluster bounces.

Detach with `Ctrl-b d` (standard tmux); the session keeps running. Re-attach
with `tmux attach -t okd-status`. Kill it with `tmux kill-session -t okd-status`.

## Optional config

The cluster-summary pane can also health-check arbitrary HTTP endpoints and
show load/memory for SSH-reachable hosts. Copy the example and edit:

```bash
mkdir -p ~/.config/okd-status
cp okd-status.conf.example ~/.config/okd-status/config
$EDITOR ~/.config/okd-status/config
```

```bash
SERVICES=(
  "Vault|https://vault.example.com/v1/sys/health"
  "Grafana|https://grafana.example.com/api/health"
)
SSH_HOSTS=(
  "node-a|root@10.0.0.11"
)
```

Or keep it elsewhere and pass `OKD_STATUS_CONF=/path/to/config`. Without a
config file these sections are simply omitted.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `KUBECONFIG` | `~/.kube/config` | cluster to talk to |
| `OKD_STATUS_CONF` | `~/.config/okd-status/config` | optional config path |
| `OKD_STATUS_SESSION` | `okd-status` | tmux session name |

## How it works

There's no magic: `okd-status.sh` writes a handful of tiny loop scripts to
`/tmp`, builds a tmux session, and runs one loop per pane. Each loop polls `oc`,
colour-codes the output with ANSI escapes, and calls `tmux resize-pane` to fit
its content. It's a single file you can read top to bottom in a few minutes.

## License

MIT — see [LICENSE](LICENSE).
