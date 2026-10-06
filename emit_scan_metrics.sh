#!/usr/bin/env bash
# =====================================================================
# emit_scan_metrics.sh -- publish one image's scan results to Prometheus
# via the node_exporter textfile collector.
#
# Usage:
#   emit_scan_metrics.sh <image_name> <image_version> <vuln_json> <scan_log>
#
#   image_name     e.g. nucleus/nginx  (no tag -- one series set per image,
#                  so the trend follows the image across rebuilds)
#   image_version  e.g. 1.31.6         (reported separately, as image_scan_info)
#   vuln_json      Grype JSON written by sbom_generate_and_scan.sh
#   scan_log       the scan's log; the compensating-control report inside it
#                  is parsed for dispositions and leftover files
#
# Metrics written (one atomic file per image):
#   image_vulns{image,severity}               findings per severity (0 included)
#   image_vuln_fix_state{image,state}         findings by Grype fix state
#   image_compensating_groups{image,disposition}  groups: accepted / not_mitigated / removable
#   image_leftover_files{image,group}         files still PRESENT per package group
#   image_scan_info{image,version}            version that was scanned
#   image_scan_timestamp_seconds{image}       when metrics were written
#
# Exit codes: 0 ok, 1 could not publish (caller treats as a warning),
#             2 usage error.
# =====================================================================

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

main() {
  local image="${1:-}" version="${2:-}" vuln_json="${3:-}" scan_log="${4:-}"

  if [[ -z "$image" || -z "$vuln_json" ]]; then
    echo "usage: emit_scan_metrics.sh <image_name> <image_version> <vuln_json> <scan_log>" >&2
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { echo "emit_scan_metrics: jq not found" >&2; return 1; }
  [[ -r "$vuln_json" ]]         || { echo "emit_scan_metrics: cannot read $vuln_json" >&2; return 1; }

  # ---- 1. Vulnerability counts (authoritative: the Grype JSON) --------
  local sev_lines fix_lines
  sev_lines="$(jq -r '(.matches // []) as $m
      | ["Critical","High","Medium","Low","Negligible","Unknown"][] as $s
      | "\($s)\t\([$m[] | select(.vulnerability.severity == $s)] | length)"' "$vuln_json")" \
    || { echo "emit_scan_metrics: could not parse $vuln_json" >&2; return 1; }
  fix_lines="$(jq -r '(.matches // []) as $m
      | ["fixed","not-fixed","wont-fix","unknown"][] as $s
      | "\($s)\t\([$m[] | select((.vulnerability.fix.state // "unknown") == $s)] | length)"' "$vuln_json")" \
    || return 1

  # ---- 2. Compensating-control report (parsed from the scan log) ------
  local ctl_lines=""
  if [[ -n "$scan_log" && -r "$scan_log" ]]; then
    ctl_lines="$(awk '
      /^=== Compensating-Control Verification Report ===/ { inrep = 1; next }
      /^Verification complete\./                           { inrep = 0 }
      !inrep { next }
      /^-- .* --$/ {
          g = $0; sub(/^-- /, "", g); sub(/ --$/, "", g)
          if (!(g in seen)) { seen[g] = 1; order[++n] = g }
          next }
      /^PRESENT:/ { if (g != "") present[g]++; next }
      /^DISPOSITION:/ {
          if      ($0 ~ /NOT MITIGATED, but likely removable/) removable++
          else if ($0 ~ /NOT MITIGATED/)                       notmit++
          else if ($0 ~ /Risk accepted/)                       accepted++
          next }
      END {
          if (n > 0) {
              printf "DISP\taccepted\t%d\n",      accepted + 0
              printf "DISP\tnot_mitigated\t%d\n", notmit + 0
              printf "DISP\tremovable\t%d\n",     removable + 0
              for (i = 1; i <= n; i++) printf "LEFT\t%s\t%d\n", order[i], present[order[i]] + 0
          } }' "$scan_log")"
  fi

  # ---- 3. Write one atomic file per image -----------------------------
  local e_img; e_img="$(esc "$image")"
  local e_ver; e_ver="$(esc "$version")"
  local fname; fname="image_scan_$(printf '%s' "$image" | tr -c 'A-Za-z0-9_' '_').prom"
  local out="${TEXTFILE_DIR}/${fname}"
  mkdir -p "$TEXTFILE_DIR" || return 1
  local tmp; tmp="$(mktemp "${TEXTFILE_DIR}/.${fname}.XXXXXX")" || return 1

  {
    echo "# HELP image_vulns Vulnerability findings per severity (Grype) for the latest scan."
    echo "# TYPE image_vulns gauge"
    while IFS=$'\t' read -r k v; do
      [[ -n "$k" ]] && echo "image_vulns{image=\"${e_img}\",severity=\"${k}\"} ${v}"
    done <<< "$sev_lines"

    echo "# HELP image_vuln_fix_state Vulnerability findings by Grype fix state."
    echo "# TYPE image_vuln_fix_state gauge"
    while IFS=$'\t' read -r k v; do
      [[ -n "$k" ]] && echo "image_vuln_fix_state{image=\"${e_img}\",state=\"${k}\"} ${v}"
    done <<< "$fix_lines"

    if [[ -n "$ctl_lines" ]]; then
      echo "# HELP image_compensating_groups Package groups by compensating-control disposition."
      echo "# TYPE image_compensating_groups gauge"
      while IFS=$'\t' read -r kind a b; do
        [[ "$kind" == "DISP" ]] && echo "image_compensating_groups{image=\"${e_img}\",disposition=\"${a}\"} ${b}"
      done <<< "$ctl_lines"

      echo "# HELP image_leftover_files Files still present per package group (hardening progress)."
      echo "# TYPE image_leftover_files gauge"
      while IFS=$'\t' read -r kind a b; do
        [[ "$kind" == "LEFT" ]] && echo "image_leftover_files{image=\"${e_img}\",group=\"$(esc "$a")\"} ${b}"
      done <<< "$ctl_lines"
    fi

    echo "# HELP image_scan_info Version of the image that was scanned."
    echo "# TYPE image_scan_info gauge"
    echo "image_scan_info{image=\"${e_img}\",version=\"${e_ver}\"} 1"
    echo "# HELP image_scan_timestamp_seconds Unix time the scan metrics were written."
    echo "# TYPE image_scan_timestamp_seconds gauge"
    echo "image_scan_timestamp_seconds{image=\"${e_img}\"} $(date +%s)"
  } > "$tmp"

  chmod 0644 "$tmp"
  mv -f "$tmp" "$out"
  echo "Scan metrics written: $out"
}

main "$@"
exit $?
