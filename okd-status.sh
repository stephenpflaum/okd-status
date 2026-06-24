#!/usr/bin/env zsh
# okd-status.sh — a live tmux dashboard for an OpenShift / OKD cluster.
#
# Splits a tmux window into self-resizing panes:
#   ┌────────────────────────┬──────────────────────────────┐
#   │ infra (cluster summary │ cluster (node usage / firing  │
#   │  + optional checks)    │  alerts)                      │
#   ├────────────────────────┴──────────────────────────────┤
#   │ nodes      — `oc get nodes`, colour-coded              │
#   │ mcp        — machine config pools                      │
#   │ operators  — cluster version + `oc get co` anomalies   │
#   │ pods       — non-running pods only (fills space)       │
#   │ events     — live `oc get events -w` stream            │
#   └───────────────────────────────────────────────────────┘
#
# Everything is driven by `oc` against your current context — no host-specific
# assumptions. Point it at any cluster via KUBECONFIG or your kube context.
#
# Optional extras (service endpoint + SSH host checks) are read from a config
# file; see okd-status.conf.example. Without one, the infra pane just shows the
# generic cluster summary.
#
# Usage:
#   ./okd-status.sh
#   # optionally replace the bottom events pane with a custom log follow:
#   ./okd-status.sh "oc logs -f -n openshift-machine-config-operator deploy/machine-config-operator"
#
# Requirements: oc, tmux, python3, awk (curl + ssh only if you use the config).

# Use the current kube context unless KUBECONFIG is already set.
: "${KUBECONFIG:=$HOME/.kube/config}"
export KUBECONFIG
SESSION="${OKD_STATUS_SESSION:-okd-status}"
# Optional config file with SERVICES / SSH_HOSTS arrays (see .conf.example).
CONF="${OKD_STATUS_CONF:-$HOME/.config/okd-status/config}"
LOG_CMD="${1:-}"

# ── helper panes ────────────────────────────────────────────────────────────────
# Each pane is a small self-contained script written to /tmp and run in its own
# loop. They share the same KUBECONFIG and a common colour palette.

cat > /tmp/okd-infra.sh << 'SCRIPT'
#!/usr/bin/env bash
# Top-left pane: a generic cluster summary (version, nodes, operators, MCPs)
# plus OPTIONAL user-defined checks loaded from $OKD_STATUS_CONF:
#   SERVICES=( "Name|https://endpoint/health" ... )  -> HTTP status checks
#   SSH_HOSTS=( "label|user@host" ... )              -> load average + memory
# Self-resizes to fit its content; owns the height of the top row.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[0;36m'; W='\033[1;37m'; D='\033[0;90m'; N='\033[0m'

# Load optional config (may define SERVICES and/or SSH_HOSTS bash arrays).
[ -n "$OKD_STATUS_CONF" ] && [ -f "$OKD_STATUS_CONF" ] && source "$OKD_STATUS_CONF"

while true; do
  buf=$(
    printf "${W}━━━ CLUSTER "; printf '%.0s━' {1..58}; printf "${N}\n"

    # Cluster version + availability
    ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
    avail=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
    prog=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
    if [ -z "$ver" ]; then
      printf " ${R}●${N} API: ${R}unreachable${N}\n"
    else
      if [ "$avail" = "True" ]; then dot="${G}●${N}"; else dot="${R}●${N}"; fi
      extra=""; [ "$prog" = "True" ] && extra=" ${Y}(upgrading)${N}"
      printf " ${dot} version ${W}%s${N}${extra}\n" "$ver"
    fi

    # Nodes — ready vs NotReady
    ns=$(oc get nodes --no-headers 2>/dev/null)
    if [ -n "$ns" ]; then
      total=$(printf '%s\n' "$ns" | grep -c .)
      notready=$(printf '%s\n' "$ns" | awk '$2 ~ /NotReady/' | grep -c .)
      ready=$(( total - notready ))
      if [ "$notready" -gt 0 ]; then dot="${R}●${N}"; else dot="${G}●${N}"; fi
      printf " ${dot} nodes ${W}%s${N}/%s ready" "$ready" "$total"
      [ "$notready" -gt 0 ] && printf " ${R}(%s NotReady)${N}" "$notready"
      printf "\n"
    fi

    # Cluster operators — degraded / progressing roll-up
    co=$(oc get co --no-headers 2>/dev/null)
    if [ -n "$co" ]; then
      ct=$(printf '%s\n' "$co" | awk 'NF>=5' | grep -c .)
      deg=$(printf '%s\n' "$co" | awk '$5=="True"' | grep -c .)
      cprog=$(printf '%s\n' "$co" | awk '$4=="True"' | grep -c .)
      if [ "$deg" -gt 0 ]; then dot="${R}●${N}"; elif [ "$cprog" -gt 0 ]; then dot="${Y}●${N}"; else dot="${G}●${N}"; fi
      printf " ${dot} operators ${W}%s${N} total" "$ct"
      [ "$deg"   -gt 0 ] && printf " ${R}%s degraded${N}" "$deg"
      [ "$cprog" -gt 0 ] && printf " ${Y}%s progressing${N}" "$cprog"
      [ "$deg" -eq 0 ] && [ "$cprog" -eq 0 ] && printf " ${G}all available${N}"
      printf "\n"
    fi

    # Machine config pools — updating / degraded
    mcp=$(oc get mcp --no-headers 2>/dev/null)
    if [ -n "$mcp" ]; then
      updating=$(printf '%s\n' "$mcp" | awk '$4=="True"' | grep -c .)
      degraded=$(printf '%s\n' "$mcp" | awk '$5=="True"' | grep -c .)
      if [ "$degraded" -gt 0 ]; then dot="${R}●${N}"; elif [ "$updating" -gt 0 ]; then dot="${Y}●${N}"; else dot="${G}●${N}"; fi
      printf " ${dot} machine config pools"
      [ "$updating" -gt 0 ] && printf " ${Y}%s updating${N}" "$updating"
      [ "$degraded" -gt 0 ] && printf " ${R}%s degraded${N}" "$degraded"
      [ "$updating" -eq 0 ] && [ "$degraded" -eq 0 ] && printf " ${G}all up to date${N}"
      printf "\n"
    fi

    # Firing alerts roll-up (warning/critical, Watchdog excluded). A count
    # only — the node-usage pane on the right lists them by name.
    aj=$(oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
           curl -s --max-time 5 http://localhost:9090/api/v1/alerts 2>/dev/null)
    acnt=$(printf '%s' "$aj" | python3 -c '
import sys, json
try:
    a = json.load(sys.stdin)["data"]["alerts"]
except Exception:
    print("ERR"); sys.exit()
f = [x for x in a if x.get("state") == "firing"
     and x["labels"].get("alertname") != "Watchdog"
     and x["labels"].get("severity") in ("warning", "critical")]
crit = sum(1 for x in f if x["labels"].get("severity") == "critical")
print("%d %d" % (len(f), crit))
' 2>/dev/null)
    if [ -z "$acnt" ] || [ "$acnt" = "ERR" ]; then
      printf " ${D}● alerts unavailable${N}\n"
    else
      tot=${acnt%% *}; crit=${acnt##* }
      if [ "${tot:-0}" -eq 0 ]; then
        printf " ${G}●${N} alerts ${G}none firing${N}\n"
      elif [ "${crit:-0}" -gt 0 ]; then
        printf " ${R}●${N} alerts ${R}%s firing${N} ${D}(%s critical)${N}\n" "$tot" "$crit"
      else
        printf " ${Y}●${N} alerts ${Y}%s firing${N}\n" "$tot"
      fi
    fi

    # Optional: user-defined service endpoint checks
    if [ "${#SERVICES[@]}" -gt 0 ]; then
      echo ""
      printf "${W}━━━ SERVICES "; printf '%.0s━' {1..57}; printf "${N}\n"
      for svc in "${SERVICES[@]}"; do
        name="${svc%%|*}"; url="${svc#*|}"
        code=$(curl -sk --connect-timeout 2 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
        if [[ "$code" -ge 200 ]] 2>/dev/null && [[ "$code" -lt 400 ]] 2>/dev/null; then
          printf " ${G}●${N} %-14s ${G}%s${N}\n" "$name" "$code"
        else
          printf " ${R}●${N} %-14s ${R}%s${N}\n" "$name" "${code:-timeout}"
        fi
      done
    fi

    # Optional: user-defined SSH host load average + memory
    if [ "${#SSH_HOSTS[@]}" -gt 0 ]; then
      echo ""
      printf "${W}━━━ HOSTS "; printf '%.0s━' {1..60}; printf "${N}\n"
      for h in "${SSH_HOSTS[@]}"; do
        label="${h%%|*}"; target="${h#*|}"
        hdr=$(ssh -o ConnectTimeout=2 -o BatchMode=yes "$target" "
          load=\$(awk '{print \$1, \$2, \$3}' /proc/loadavg)
          mem=\$(free -h | awk '/Mem:/{printf \"%s/%s\", \$3, \$2}')
          echo \"\$load|\$mem\"
        " 2>/dev/null)
        if [ -n "$hdr" ]; then
          load=$(echo "$hdr" | cut -d'|' -f1); mem=$(echo "$hdr" | cut -d'|' -f2)
          printf " ${G}●${N} ${C}%-12s${N} ${D}ld %s  mem %s${N}\n" "$label" "${load:-?}" "${mem:-?}"
        else
          printf " ${R}●${N} ${C}%-12s${N} ${R}unreachable${N}\n" "$label"
        fi
      done
    fi
  )
  clear
  printf '%s\n' "$buf"
  lines=$(( $(printf '%s\n' "$buf" | wc -l) + 1 ))
  tmux resize-pane -t "$TMUX_PANE" -y "$lines" 2>/dev/null
  sleep 30
done
SCRIPT
chmod +x /tmp/okd-infra.sh

cat > /tmp/okd-cluster.sh << 'SCRIPT'
#!/usr/bin/env bash
# Top-right pane: OKD node resource usage and firing alerts. Does NOT call
# tmux resize — the infra pane on the left owns the top-row height, so this
# filler never starves the panes below it.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[0;36m'; W='\033[1;37m'; D='\033[0;90m'; N='\033[0m'
hr() {  # full-width section rule:  hr "TITLE"
  w=$(tmux display -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null); w=${w:-70}
  n=$(( w - ${#1} - 6 )); (( n < 3 )) && n=3
  printf "${W}━━━ %s " "$1"; for ((k=0;k<n;k++)); do printf '━'; done; printf "${N}\n"
}
while true; do
  buf=$(
    # OKD node resource usage
    hr "NODE USAGE (cpu / mem)"
    # Map node -> Ready condition (Ready / NotReady / SchedulingDisabled)
    ns=$(oc get nodes --no-headers 2>/dev/null)
    if nu=$(oc adm top nodes --no-headers 2>/dev/null) && [ -n "$nu" ]; then
      printf '%s\n' "$nu" | while read -r name cpu cpup mem memp _; do
        st=$(printf '%s\n' "$ns" | awk -v n="$name" '$1==n{print $2; exit}')
        # if/elif, not case: bash 3.2 misparses `case ... )` inside $() (buf=...)
        if [[ "$st" == *NotReady* ]]; then            dot="${R}●${N}"
        elif [[ "$st" == *SchedulingDisabled* ]]; then dot="${Y}●${N}"
        elif [[ "$st" == Ready* ]]; then               dot="${G}●${N}"
        else                                           dot="${D}○${N}"
        fi
        printf "  ${dot} %-12s ${D}%6s %4s${N}  %8s ${D}%4s${N}\n" "$name" "$cpu" "$cpup" "$mem" "$memp"
      done
    else
      printf " ${D}metrics unavailable${N}\n"
    fi

    # Firing alerts — in-cluster Prometheus (service proxy is often blocked; exec works).
    # Drop the always-on Watchdog and info-level noise.
    echo ""
    aj=$(oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
           curl -s --max-time 5 http://localhost:9090/api/v1/alerts 2>/dev/null)
    parsed=$(printf '%s' "$aj" | python3 -c '
import sys, json, collections
try:
    a = json.load(sys.stdin)["data"]["alerts"]
except Exception:
    print("__ERR__"); sys.exit()
f = [x for x in a if x.get("state") == "firing"
     and x["labels"].get("alertname") != "Watchdog"
     and x["labels"].get("severity") in ("warning", "critical")]
seen = collections.OrderedDict()
for x in f:
    k = (x["labels"].get("severity"), x["labels"].get("alertname"))
    seen[k] = seen.get(k, 0) + 1
order = {"critical": 0, "warning": 1}
print("COUNT %d" % len(f))
for (sev, name), c in sorted(seen.items(), key=lambda kv: order.get(kv[0][0], 9))[:8]:
    print("%s\t%s\t%s" % (sev, name, ("x%d" % c if c > 1 else "")))
extra = len(seen) - 8
if extra > 0: print("MORE %d" % extra)
' 2>/dev/null)
    if [ -z "$parsed" ] || printf '%s' "$parsed" | grep -q __ERR__; then
      hr "ALERTS"; printf " ${D}unavailable${N}\n"
    else
      cnt=$(printf '%s\n' "$parsed" | awk '/^COUNT/{print $2}')
      hr "ALERTS (${cnt:-0} firing)"
      if [ "${cnt:-0}" = "0" ]; then
        printf " ${G}● none (warning/critical)${N}\n"
      else
        printf '%s\n' "$parsed" | grep -vE '^COUNT|^MORE' | while IFS=$'\t' read -r sev name c; do
          if [ "$sev" = "critical" ]; then col="$R"; else col="$Y"; fi
          printf " ${col}⚠ %-28s${N} ${D}%s %s${N}\n" "$name" "$sev" "$c"
        done
        printf '%s\n' "$parsed" | awk -v d="$D" -v n="$N" '/^MORE/{printf "   %s+%s more%s\n",d,$2,n}'
      fi
    fi
  )
  clear
  printf '%s\n' "$buf"
  sleep 45
done
SCRIPT
chmod +x /tmp/okd-cluster.sh

cat > /tmp/okd-nodes.sh << 'SCRIPT'
#!/usr/bin/env bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
while true; do
  output=$(oc get nodes 2>&1)

  # Tally STATUS ($2): Ready-like (incl. cordoned) vs NotReady, with
  # SchedulingDisabled and any unknown state counted separately. `healthy`
  # = Ready and NOT cordoned — these are the rows we hide from the body.
  read -r rdy nr sd healthy other <<<"$(printf '%s\n' "$output" | awk '
    NR==1 || NF<2 { next }
    {
      s=$2
      if (s ~ /NotReady/)              { nr++ }
      else if (s ~ /(^|,)Ready(,|$)/) { rdy++; if (s !~ /SchedulingDisabled/) healthy++ }
      else                            { other++ }
      if (s ~ /SchedulingDisabled/)   { sd++ }
    }
    END { printf "%d %d %d %d %d", rdy+0, nr+0, sd+0, healthy+0, other+0 }
  ')"
  shown=$(( rdy + nr + other - healthy ))

  # Banner colour: red on NotReady/unknown, yellow on cordoned, else green
  if [[ "$nr" -gt 0 || "$other" -gt 0 ]]; then
    hdr='\033[1;31m'
  elif [[ "$sd" -gt 0 ]]; then
    hdr='\033[1;33m'
  else
    hdr='\033[1;32m'
  fi

  # Counts shown in the banner
  summary="${rdy} Ready · ${nr} NotReady"
  [[ "$sd"    -gt 0 ]] && summary="${summary} · ${sd} SchedulingDisabled"
  [[ "$other" -gt 0 ]] && summary="${summary} · ${other} Other"

  # Body: only NON-green nodes (NotReady, cordoned, or unknown state). Healthy
  # nodes (Ready and not SchedulingDisabled) are hidden — the banner still
  # counts them. The column header is kept separate so it only shows when there
  # is at least one anomaly to label.
  header=$(printf '%s\n' "$output" | awk 'NR==1{print "\033[1;37m" $0 "\033[0m"}')
  body=$(printf '%s\n' "$output" | awk '
    NR==1                       { next }
    /NotReady/                  { print "\033[1;31m" $0 "\033[0m"; next }
    /SchedulingDisabled/        { print "\033[1;33m" $0 "\033[0m"; next }
    $2 ~ /(^|,)Ready(,|$)/      { next }
                                { print "\033[1;31m" $0 "\033[0m" }
  ')

  clear
  printf "${hdr}━━━ NODES  ${summary} "; printf '%.0s━' {1..30}; printf '\033[0m\n'
  if [[ -z "$body" ]]; then
    printf '\033[1;32m  all %s nodes Ready\033[0m\n' "$rdy"
    lines=3
  else
    printf '%s\n' "$header"
    printf '%s\n' "$body"
    lines=$(( $(printf '%s\n' "$body" | wc -l) + 3 ))
  fi
  tmux resize-pane -t "$TMUX_PANE" -y "$lines" 2>/dev/null
  sleep 10
done
SCRIPT
chmod +x /tmp/okd-nodes.sh

cat > /tmp/okd-mcp.sh << 'SCRIPT'
#!/usr/bin/env bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
while true; do
  output=$(oc get mcp 2>&1)
  lines=$(( $(printf '%s\n' "$output" | wc -l) + 2 ))
  if printf '%s\n' "$output" | awk 'NR>1 && $5=="True" {found=1} END {exit !found}'; then
    mcp_hdr='\033[1;31m'
  elif printf '%s\n' "$output" | awk 'NR>1 && $4=="True" {found=1} END {exit !found}'; then
    mcp_hdr='\033[1;33m'
  else
    mcp_hdr='\033[1;32m'
  fi
  clear
  printf "${mcp_hdr}━━━ MACHINE CONFIG POOLS "; printf '%.0s━' {1..46}; printf '\033[0m\n'
  printf '%s\n' "$output" | awk '
    NR==1        { print "\033[1;37m" $0 "\033[0m"; next }
    $5 == "True" { print "\033[1;31m" $0 "\033[0m"; next }
    $4 == "True" { print "\033[1;33m" $0 "\033[0m"; next }
    $3 == "True" { print "\033[1;32m" $0 "\033[0m"; next }
                 { print "\033[2m"    $0 "\033[0m" }
  '
  tmux resize-pane -t "$TMUX_PANE" -y "$lines" 2>/dev/null
  sleep 20
done
SCRIPT
chmod +x /tmp/okd-mcp.sh

cat > /tmp/okd-ops.sh << 'SCRIPT'
#!/usr/bin/env bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
while true; do
  ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
  avail=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  output=$(oc get co 2>&1)
  total=$(printf '%s\n' "$output" | awk 'NR>1 && NF>=5' | wc -l | tr -d ' ')
  green=$(printf '%s\n' "$output" | awk 'NR>1 && $3=="True" && $4=="False" && $5=="False"' | wc -l | tr -d ' ')
  shown=$(( total - green ))
  lines=$(( shown + 4 ))
  clear
  if [[ "$avail" == "True" ]]; then
    printf '\033[1;32m━━━ OPERATORS  version: %s ' "$ver"; printf '%.0s━' {1..40}; printf '\033[0m\n'
  else
    printf '\033[1;31m━━━ OPERATORS  version: %s (unavailable) ' "$ver"; printf '%.0s━' {1..20}; printf '\033[0m\n'
  fi
  if [[ "$shown" -eq 0 ]]; then
    printf '\033[1;32m  all %s operators green\033[0m\n' "$total"
  else
    printf '\033[0;90m  showing %s anomalies (%s green hidden)\033[0m\n' "$shown" "$green"
    printf '%s\n' "$output" | awk '
      NR==1                                              { print "\033[1;37m" $0 "\033[0m"; next }
      $3 == "True" && $4 == "False" && $5 == "False"     { next }
      $5 == "True"                                       { print "\033[1;31m" $0 "\033[0m"; next }
      $4 == "True"                                       { print "\033[1;33m" $0 "\033[0m"; next }
                                                         { print "\033[2m"    $0 "\033[0m" }
    '
  fi
  tmux resize-pane -t "$TMUX_PANE" -y "$lines" 2>/dev/null
  sleep 30
done
SCRIPT
chmod +x /tmp/okd-ops.sh

cat > /tmp/okd-pods.sh << 'SCRIPT'
#!/usr/bin/env bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
while true; do
  body=$(oc get pods -A 2>&1 | awk '
    NR==1                              { print "\033[1;37m" $0 "\033[0m"; next }
    $4 == "Running"                    { next }
    $4 == "Completed" || $4 == "Succeeded" { next }
    /CrashLoopBackOff|Error|OOMKill|ImagePullBackOff|ErrImagePull/ \
                                       { print "\033[1;31m" $0 "\033[0m"; next }
    /Pending|Init:|PodInitializing|ContainerCreating|Terminating/ \
                                       { print "\033[1;33m" $0 "\033[0m"; next }
                                       { print "\033[1;31m" $0 "\033[0m" }
  ')
  clear
  printf '\033[1;37m━━━ PODS (non-running) '; printf '%.0s━' {1..48}; printf '\033[0m\n'
  if [[ -z "$body" ]]; then
    printf '\033[1;32m  no non-running pods\033[0m\n'
    lines=3
  else
    printf '%s\n' "$body"
    lines=$(( $(printf '%s\n' "$body" | wc -l) + 2 ))
  fi
  tmux resize-pane -t "$TMUX_PANE" -y "$lines" 2>/dev/null
  sleep 15
done
SCRIPT
chmod +x /tmp/okd-pods.sh

cat > /tmp/okd-events.sh << 'SCRIPT'
#!/usr/bin/env bash
# Live event stream with auto-reconnect — `oc get events -w` exits on watch
# timeout, API blip, or cluster bounce; this loop reattaches forever.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
attempt=0
while true; do
  attempt=$((attempt + 1))
  if [ "$attempt" -eq 1 ]; then
    printf '\033[1;37m━━━ LIVE EVENTS '; printf '%.0s━' {1..55}; printf '\033[0m\n'
  else
    printf '\033[1;36m━━ reattached event stream (attempt %s) at %s ━━\033[0m\n' \
      "$attempt" "$(date '+%H:%M:%S')"
  fi
  oc get events -w -A --watch-only 2>&1 | awk '
    NR==1                          { print "\033[1;37m" $0 "\033[0m"; fflush(); next }
    /\bWarning\b/                  { print "\033[1;33m" $0 "\033[0m"; fflush(); next }
    /BackOff|OOMKill|Failed|Error/ { print "\033[1;31m" $0 "\033[0m"; fflush(); next }
    /\bNormal\b/                   { print "\033[32m"   $0 "\033[0m"; fflush(); next }
                                   { print "\033[2m"    $0 "\033[0m"; fflush() }
  '
  rc=${PIPESTATUS[0]}
  printf '\033[1;33m━━ event stream exited (rc=%s); reconnecting in 3s ━━\033[0m\n' "$rc"
  sleep 3
done
SCRIPT
chmod +x /tmp/okd-events.sh

# Generic reattaching wrapper for user-supplied log commands (e.g.
# `oc logs -f deploy/X`) — same loop semantics as okd-events.sh.
cat > /tmp/okd-log-reattach.sh << 'SCRIPT'
#!/usr/bin/env bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
CMD="$*"
[ -z "$CMD" ] && { echo "usage: okd-log-reattach.sh <command>" >&2; exit 2; }
attempt=0
while true; do
  attempt=$((attempt + 1))
  if [ "$attempt" -eq 1 ]; then
    printf '\033[1;37m━━━ LOG: %s ━━━\033[0m\n' "$CMD"
  else
    printf '\033[1;36m━━ reattached (attempt %s) at %s ━━\033[0m\n' \
      "$attempt" "$(date '+%H:%M:%S')"
  fi
  bash -c "$CMD"
  rc=$?
  printf '\033[1;33m━━ command exited (rc=%s); reconnecting in 3s ━━\033[0m\n' "$rc"
  sleep 3
done
SCRIPT
chmod +x /tmp/okd-log-reattach.sh

# ── tmux session ─────────────────────────────────────────────────────────────────

tmux kill-session -t "$SESSION" 2>/dev/null || true

# Prefix env carried into every pane (tmux send-keys runs a fresh shell).
ENV="KUBECONFIG=$KUBECONFIG OKD_STATUS_CONF=$CONF"

# Create the session at the real terminal size. A bare `new-session -d`
# defaults to 80x24, which is too short for all the vertical splits — a split
# fails ("no space for new pane"), its var goes empty, and a pane script
# clobbers another. Seed with the launching tty's dimensions (fallback to a
# large size when not on a tty, e.g. invoked headless).
COLS=$(tput cols 2>/dev/null); LINES=$(tput lines 2>/dev/null)
[[ "$COLS"  =~ ^[0-9]+$ ]] && (( COLS  >= 80 )) || COLS=236
[[ "$LINES" =~ ^[0-9]+$ ]] && (( LINES >= 40 )) || LINES=60

# Build panes: (infra | cluster) / nodes / mcp / ops / pods / events.
# Top row is split horizontally: infra (left, tall — owns the row height) and
# cluster info (right, shorter). The lower panes are -v splits off infra, so
# each new one inserts directly below it and pushes the earlier ones down.
PANE_INFRA=$(tmux new-session -d -s "$SESSION" -x "$COLS" -y "$LINES" -P -F "#{pane_id}")

# events: fixed bottom 15%
PANE_EVENTS=$(tmux split-window -v -p 15 -t "$PANE_INFRA" -P -F "#{pane_id}")

# pods: above events
PANE_PODS=$(tmux split-window -v -p 50 -t "$PANE_INFRA" -P -F "#{pane_id}")

# ops: above pods
PANE_OPS=$(tmux split-window -v -p 60 -t "$PANE_INFRA" -P -F "#{pane_id}")

# mcp: above ops
PANE_MCP=$(tmux split-window -v -p 20 -t "$PANE_INFRA" -P -F "#{pane_id}")

# nodes: above mcp
PANE_NODES=$(tmux split-window -v -p 25 -t "$PANE_INFRA" -P -F "#{pane_id}")

# cluster info: right portion of the top (infra) row — added LAST so only the
# top row splits horizontally. The left infra pane self-resizes and owns the
# row height, so this filler can't squeeze the panes below.
PANE_CLUSTER=$(tmux split-window -h -p 58 -t "$PANE_INFRA" -P -F "#{pane_id}")

# Send commands
tmux send-keys -t "$PANE_INFRA"   "$ENV /tmp/okd-infra.sh"   Enter
tmux send-keys -t "$PANE_CLUSTER" "$ENV /tmp/okd-cluster.sh" Enter
tmux send-keys -t "$PANE_NODES"   "$ENV /tmp/okd-nodes.sh"   Enter
tmux send-keys -t "$PANE_MCP"     "$ENV /tmp/okd-mcp.sh"     Enter
tmux send-keys -t "$PANE_OPS"     "$ENV /tmp/okd-ops.sh"     Enter
tmux send-keys -t "$PANE_PODS"    "$ENV /tmp/okd-pods.sh"    Enter

if [[ -n "$LOG_CMD" ]]; then
  tmux send-keys -t "$PANE_EVENTS" "$ENV /tmp/okd-log-reattach.sh $LOG_CMD" Enter
else
  tmux send-keys -t "$PANE_EVENTS" "$ENV /tmp/okd-events.sh" Enter
fi

tmux select-pane -t "$PANE_EVENTS"

if [[ -n "$TMUX" ]]; then
  tmux switch-client -t "$SESSION"
else
  tmux attach-session -t "$SESSION"
fi
