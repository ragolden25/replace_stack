#!/usr/bin/env bash
# =====================================================================
# emit_build_metrics.sh -- publish metrics from one finished stack build
# log (Guacamole / Grafana) via the node_exporter textfile collector.
#
# Usage:
#   emit_build_metrics.sh <build_log> <stack>
#
#   build_log  the log written by play_build_*.sh (ansible-playbook -vvv
#              output plus the "=== Build started/finished ===" lines)
#   stack      guacamole | grafana   (becomes the "stack" label)
#
# Metrics written (one atomic file per stack):
#   build_run_duration_seconds{stack}            wall time of the whole run
#   build_run_tasks{stack,result}                PLAY RECAP counts: ok, changed,
#                                                failed, skipped, rescued, ignored,
#                                                unreachable
#   build_ignored_failures{stack,task}           tasks that FAILED but were ignored
#                                                (ignore_errors) -- count per task
#   build_slowest_task_seconds{stack,task}       5 longest-running command tasks
#   build_run_timestamp_seconds{stack}           when metrics were written
#
# Exit codes: 0 ok, 1 could not publish (caller treats as a warning),
#             2 usage error.
# =====================================================================

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r'; }

main() {
  local log="${1:-}" stack="${2:-}"
  if [[ -z "$log" || -z "$stack" ]]; then
    echo "usage: emit_build_metrics.sh <build_log> <stack>" >&2
    return 2
  fi
  [[ -r "$log" ]] || { echo "emit_build_metrics: cannot read $log" >&2; return 1; }

  # One pass over the (often multi-MB) log.
  local parsed
  parsed="$(awk '
    function secs(d,   a, n) {            # "H:MM:SS.ffffff" -> seconds
      n = split(d, a, ":")
      if (n != 3) return -1
      return a[1] * 3600 + a[2] * 60 + a[3]
    }
    function shortname(t) {               # strip "TASK [role path : " and "] ***"
      sub(/^TASK \[/, "", t)
      sub(/\][ \t\r]*\*+[ \t\r]*$/, "", t)
      sub(/^.* : /, "", t)
      return t
    }
    /^=== Build started at /  { s = $0; sub(/^=== Build started at /, "", s); sub(/ ===$/, "", s); print "START\t" s }
    /^=== Build finished at / { s = $0; sub(/^=== Build finished at /, "", s); sub(/ ===$/, "", s); print "END\t" s }
    /^=== Total time: /      { m = $4 + 0; sc = $6 + 0; print "TOTAL\t" (m * 60 + sc) }
    /^=== Build FAILED/      { print "FAILED\t1" }

    /^TASK \[/ { task = shortname($0); next }

    # "...ignoring" is printed by Ansible after any failed task that has
    # ignore_errors set (fatal: lines are not always present, e.g. rc!=0 commands).
    /^\.\.\.ignoring/ { if (task != "") ign[task]++; next }

    /^[A-Za-z0-9_.-]+ +: ok=/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^[a-z]+=[0-9]+$/) {
        split($i, kv, "=")
        rec[kv[1]] += kv[2]
      }
    }

    # Only command-type tasks report a delta. Keep the longest per task.
    /^ +"delta": "/ {
      if (task != "") {
        d = $0; sub(/^ +"delta": "/, "", d); sub(/".*$/, "", d)
        v = secs(d)
        if (v > best[task]) best[task] = v
      }
    }

    END {
      for (k in rec) print "REC\t" k "\t" rec[k]
      for (t in ign) print "IGN\t" t "\t" ign[t]
      for (t in best) print "TASK\t" t "\t" best[t]
    }' "$log")" || { echo "emit_build_metrics: could not parse $log" >&2; return 1; }

  # ---- duration: prefer the wrapper's own total, fall back to end-start ----
  local duration start end
  duration="$(awk -F'\t' '$1=="TOTAL"{print $2; exit}' <<<"$parsed")"
  if [[ -z "$duration" ]]; then
    start="$(awk -F'\t' '$1=="START"{print $2; exit}' <<<"$parsed")"
    end="$(awk -F'\t' '$1=="END"{print $2; exit}' <<<"$parsed")"
    if [[ -n "$start" && -n "$end" ]]; then
      # 2026-10-05-09:57:44 -> 2026-10-05 09:57:44
      local s e
      s="$(date -d "${start:0:10} ${start:11}" +%s 2>/dev/null)" || s=""
      e="$(date -d "${end:0:10} ${end:11}" +%s 2>/dev/null)" || e=""
      [[ -n "$s" && -n "$e" ]] && duration=$((e - s))
    fi
  fi

  local e_stack; e_stack="$(esc "$stack")"
  local fname; fname="build_stack_$(printf '%s' "$stack" | tr -c 'A-Za-z0-9_' '_').prom"
  local out="${TEXTFILE_DIR}/${fname}"
  mkdir -p "$TEXTFILE_DIR" || return 1
  local tmp; tmp="$(mktemp "${TEXTFILE_DIR}/.${fname}.XXXXXX")" || return 1

  {
    if [[ -n "$duration" ]]; then
      echo "# HELP build_run_duration_seconds Wall time of the last stack build."
      echo "# TYPE build_run_duration_seconds gauge"
      echo "build_run_duration_seconds{stack=\"${e_stack}\"} ${duration}"
    fi

    if grep -q '^REC' <<<"$parsed"; then
      echo "# HELP build_run_tasks Ansible PLAY RECAP counts for the last build."
      echo "# TYPE build_run_tasks gauge"
      local r
      for r in ok changed failed skipped rescued ignored unreachable; do
        local v; v="$(awk -F'\t' -v k="$r" '$1=="REC" && $2==k {print $3; f=1} END{if(!f) print 0}' <<<"$parsed")"
        echo "build_run_tasks{stack=\"${e_stack}\",result=\"${r}\"} ${v}"
      done
    fi

    echo "# HELP build_ignored_failures Tasks that failed but were ignored (ignore_errors) in the last build."
    echo "# TYPE build_ignored_failures gauge"
    while IFS=$'\t' read -r kind a b; do
      [[ "$kind" == "IGN" ]] && echo "build_ignored_failures{stack=\"${e_stack}\",task=\"$(esc "$a")\"} ${b}"
    done <<<"$parsed"

    echo "# HELP build_slowest_task_seconds Longest command run inside the five slowest tasks of the last build."
    echo "# TYPE build_slowest_task_seconds gauge"
    awk -F'\t' '$1=="TASK" {print $3 "\t" $2}' <<<"$parsed" | sort -rn | head -n 5 |
    while IFS=$'\t' read -r secs name; do
      printf 'build_slowest_task_seconds{stack="%s",task="%s"} %.1f\n' "${e_stack}" "$(esc "$name")" "$secs"
    done

    echo "# HELP build_run_timestamp_seconds Unix time the build metrics were written."
    echo "# TYPE build_run_timestamp_seconds gauge"
    echo "build_run_timestamp_seconds{stack=\"${e_stack}\"} $(date +%s)"
  } > "$tmp"

  chmod 0644 "$tmp"
  mv -f "$tmp" "$out"
  echo "Build metrics written: $out"
}

main "$@"
exit $?
