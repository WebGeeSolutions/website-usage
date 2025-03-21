#!/usr/bin/env bash
##############################################################################
# usage.sh: CGroup monitoring script that does it all:
#  1) Single or all cgroups in /sys/fs/cgroup/websites/.
#  2) Interactive selection if no cgroup and not --all.
#  3) Watch mode with optional --seconds <N>.
#  4) Table or JSON output (exact structure).
#  5) Performance test measuring iteration times, peak memory, CPU usage.
#  6) Traps Ctrl+C in watch mode to print summary, then exit.
##############################################################################

# Default refresh interval for watch mode:
INTERVAL=1

WATCH_MODE=false
JSON_MODE=false
ALL_MODE=false
PERF_TEST=false

CGROUP_SINGLE=""

# We store "previous usage" data for CPU & IO in associative arrays (/!\ Bash 4+).
declare -A PREV_CPU_USAGE
declare -A PREV_RBYTES
declare -A PREV_WBYTES

# Count CPUs in pure shell (no nproc):
NUM_CPUS=0
while IFS= read -r line; do
  case "$line" in
    processor*) ((NUM_CPUS++)) ;;
  esac
done < /proc/cpuinfo

##############################################################################
# Performance test variables
##############################################################################
PERF_RUNS=0
PERF_SUM="0.000000"   # total wall-clock time across iterations
PEAK_MEM=0            # track peak RSS usage of this script (in KB)
SCRIPT_CPU_START=0    # total CPU ticks used by this script at the start
SCRIPT_CPU_END=0

# We'll guess 100 if we can't get conf:
HZ=1
if command -v getconf >/dev/null 2>&1; then
  # Typically returns 100, 250, or 1000, etc.
  HZ=$(getconf CLK_TCK)
fi

##############################################################################
# usage
##############################################################################
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [CGROUP_NAME]

Options:
  --help       Show this help
  --all        Show stats for all cgroups in /sys/fs/cgroup/websites/
  --watch      Repeat updates, clearing screen
  --seconds N  Interval for watch mode (default: 1s)
  --json       Output JSON instead of ASCII table
  --perf-test  Measure performance overhead (time/memory/CPU),
               printing a summary at the end or on Ctrl+C.

Examples:
  $0                 # Interactive single-cgroup selection
  $0 my-cgroup       # Single cgroup, one-shot
  $0 --all           # All cgroups, one-shot
  $0 --all --json    # JSON array for all cgroups
  $0 --watch --all   # Repeated table for all cgroups
  $0 --watch --seconds 5 my-cgroup
  $0 --perf-test --all
EOF
  exit 0
}

##############################################################################
# parse_arguments
##############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      ;;
    --all)
      ALL_MODE=true
      shift
      ;;
    --watch)
      WATCH_MODE=true
      shift
      ;;
    --seconds)
      shift
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        INTERVAL="$1"
        shift
      else
        echo "Error: --seconds requires a numeric argument."
        exit 1
      fi
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --perf-test)
      PERF_TEST=true
      shift
      ;;
    *)
      if [ -z "$CGROUP_SINGLE" ]; then
        CGROUP_SINGLE="$1"
      else
        echo "Error: too many arguments."
        usage
      fi
      shift
      ;;
  esac
done

##############################################################################
# get_cgroup_list: each directory => one line
##############################################################################
get_cgroup_list() {
  for entry in /sys/fs/cgroup/websites/*; do
    [ -d "$entry" ] || continue
    echo "${entry##*/}"
  done
}

##############################################################################
# partial_stats_for_list: minimal stats for interactive listing
##############################################################################
partial_stats_for_list() {
  local cgroup="$1"
  local path="/sys/fs/cgroup/websites/$cgroup"

  local owner="unknown"
  if [ -d "/var/www/$cgroup" ]; then
    owner=$(stat -c "%U" "/var/www/$cgroup" 2>/dev/null || echo "unknown")
  fi

  local mem_cur=0
  if [ -f "$path/memory.current" ]; then
    IFS= read -r mem_cur < "$path/memory.current"
  fi
  local mem_mb=$(( mem_cur / 1024 / 1024 ))

  local pid_cur=0
  if [ -f "$path/pids.current" ]; then
    IFS= read -r pid_cur < "$path/pids.current"
  fi

  echo "$owner|$mem_mb|$pid_cur"
}

##############################################################################
# print_table_header: prints a header for the ASCII table
##############################################################################
print_table_header() {
  printf "%-36s | %-10s | %7s | %5s | %11s | %8s | %14s | %9s\n" \
    "CGROUP" "OWNER" "CPU(%)" "CORES" "MEM (MB)" "MEM(%)" "IO (R/W/T)" "PIDS"
  printf "%-36s-+-%-10s-+-%7s-+-%5s-+-%11s-+-%8s-+-%14s-+-%9s\n" \
    "$(printf '%.0s-' {1..36})" \
    "$(printf '%.0s-' {1..10})" \
    "$(printf '%.0s-' {1..7})"  \
    "$(printf '%.0s-' {1..5})"  \
    "$(printf '%.0s-' {1..11})" \
    "$(printf '%.0s-' {1..8})"  \
    "$(printf '%.0s-' {1..14})" \
    "$(printf '%.0s-' {1..9})"
}


##############################################################################
# interactive_select: table for cgroups
##############################################################################
interactive_select() {
  local arr=($(get_cgroup_list))
  local count=${#arr[@]}
  if [ "$count" -eq 0 ]; then
    echo "No cgroups found in /sys/fs/cgroup/websites/."
    exit 1
  fi

  # We'll build a small table: # | CGROUP | OWNER | MEM(MB) | PIDS
  printf "%3s | %-36s | %-10s | %8s | %5s\n" \
    "#" "CGROUP" "OWNER" "MEM_MB" "PIDS"
  printf "%3s-+-%-36s-+-%-10s-+-%8s-+-%5s\n" \
    "$(printf '%.0s-' {1..3})" \
    "$(printf '%.0s-' {1..36})" \
    "$(printf '%.0s-' {1..10})" \
    "$(printf '%.0s-' {1..8})" \
    "$(printf '%.0s-' {1..5})"

  local i
  for i in "${!arr[@]}"; do
    local cgr="${arr[$i]}"
    local line
    line=$(partial_stats_for_list "$cgr")
    local owner="${line%%|*}"
    local rest="${line#*|}"
    local mm="${rest%%|*}"
    local pids="${rest##*|}"

    local cgrp="$cgr"
    if [ ${#cgrp} -gt 36 ]; then
      cgrp="${cgrp:0:33}..."
    fi

    printf "%3d | %-36s | %-10s | %8s | %5s\n" \
      $((i+1)) "$cgrp" "$owner" "$mm" "$pids"
  done

  while true; do
    echo -n "Select a number (1-$count) or 'q' to quit: "
    read -r sel
    if [[ "$sel" == "q" ]]; then
      exit 0
    fi
    if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le "$count" ]]; then
      CGROUP_SINGLE="${arr[$((sel-1))]}"
      return
    fi
    echo "Invalid selection."
  done
}

##############################################################################
# read_initial_stats: store baseline CPU/IO usage for deltas
##############################################################################
read_initial_stats() {
  for cgroup in "$@"; do
    PREV_CPU_USAGE["$cgroup"]=0
    PREV_RBYTES["$cgroup"]=0
    PREV_WBYTES["$cgroup"]=0

    local path="/sys/fs/cgroup/websites/$cgroup"

    # CPU
    if [ -f "$path/cpu.stat" ]; then
      while IFS= read -r line; do
        case "$line" in
          usage_usec\ *) PREV_CPU_USAGE["$cgroup"]="${line#usage_usec }"; break ;;
        esac
      done < "$path/cpu.stat"
    fi

    # IO
    if [ -f "$path/io.stat" ]; then
      local r=0
      local w=0
      while IFS= read -r ln; do
        for token in $ln; do
          case "$token" in
            rbytes=*) r="${token#rbytes=}" ;;
            wbytes=*) w="${token#wbytes=}" ;;
          esac
        done
      done < "$path/io.stat"
      PREV_RBYTES["$cgroup"]="$r"
      PREV_WBYTES["$cgroup"]="$w"
    fi
  done
}

##############################################################################
# get_script_cpu_ticks: parse /proc/self/stat => utime+stime in ticks
##############################################################################
get_script_cpu_ticks() {
  local statline
  IFS= read -r statline < /proc/self/stat

  # Typically: pid (comm) state ppid pgrp session tty_nr tpgid flags
  #     minflt cminflt majflt cmajflt utime stime cutime cstime ...
  # We'll do a naive array parse. Usually the comm doesn't have spaces.
  local -a arr=($statline)
  local utime="${arr[13]}"
  local stime="${arr[14]}"
  local total=$(( utime + stime ))
  echo "$total"
}

##############################################################################
# update_peak_mem: check /proc/self/status => "VmRSS:"
##############################################################################
update_peak_mem() {
  while IFS= read -r line; do
    case "$line" in
      VmRSS:*)
        local val="${line#VmRSS:}"
        val="${val## }"    # remove leading spaces
        val="${val%% *}"   # remove trailing "kB" or spaces
        [[ "$val" =~ ^[0-9]+$ ]] || val=0
        if [ "$val" -gt "$PEAK_MEM" ]; then
          PEAK_MEM="$val"
        fi
        return
        ;;
    esac
  done < /proc/self/status
}

##############################################################################
# calc_percentage: integer-based => XX.YY
##############################################################################
calc_percentage() {
  local usage="$1"
  local total="$2"
  # If not numeric, fallback to 0
  [[ "$usage" =~ ^[0-9]+$ ]] || usage=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0

  if [ "$total" -le 0 ]; then
    echo "0.00"
    return
  fi
  local scaled=$(( usage * 10000 / total ))
  local integer=$(( scaled / 100 ))
  local fraction=$(( scaled % 100 ))
  if [ $fraction -lt 10 ]; then
    echo "${integer}.0${fraction}"
  else
    echo "${integer}.${fraction}"
  fi
}

##############################################################################
# bytes_to_mb: integer-based => XX.YY
##############################################################################
bytes_to_mb() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+$ ]] || val=0
  local scaled=$(( val * 100 / 1048576 ))
  local integer=$(( scaled / 100 ))
  local fraction=$(( scaled % 100 ))
  if [ $fraction -lt 10 ]; then
    echo "${integer}.0${fraction}"
  else
    echo "${integer}.${fraction}"
  fi
}

##############################################################################
# read_and_display: get full stats for each cgroup, output table or JSON
##############################################################################
read_and_display() {
  local cgroups=("$@")

   # If we are printing ASCII table, print the header once at the start:
  if ! $JSON_MODE; then
    print_table_header
  fi

  for cgroup in "${cgroups[@]}"; do
    local path="/sys/fs/cgroup/websites/$cgroup"

    # 1) Owner
    local owner="unknown"
    if [ -d "/var/www/$cgroup" ]; then
      owner=$(stat -c "%U" "/var/www/$cgroup" 2>/dev/null || echo "unknown")
    fi

    # 2) CPU quota/period
    local cpu_quota="max"
    local cpu_period="100000"
    if [ -f "$path/cpu.max" ]; then
      IFS=' ' read -r q p < "$path/cpu.max"
      [ -n "$q" ] && cpu_quota="$q"
      [ -n "$p" ] && cpu_period="$p"
    fi

    # if it's not numeric => 0
    [[ "$cpu_quota" =~ ^[0-9]+$ ]] || cpu_quota="max"

    # 3) CPU usage => usage_usec
    local curr_cpu=0
    if [ -f "$path/cpu.stat" ]; then
      while IFS= read -r line; do
        case "$line" in
          usage_usec\ *) curr_cpu="${line#usage_usec }"; break ;;
        esac
      done < "$path/cpu.stat"
    fi
    [[ "$curr_cpu" =~ ^[0-9]+$ ]] || curr_cpu=0

    local prev_cpu="${PREV_CPU_USAGE[$cgroup]}"
    local cpu_delta=$(( curr_cpu - prev_cpu ))
    PREV_CPU_USAGE["$cgroup"]="$curr_cpu"
    if [ "$cpu_delta" -lt 0 ]; then
      cpu_delta=0
    fi

    local cpu_usage="0.00"
    if [ "$cpu_quota" = "max" ]; then
      # usage vs. NUM_CPUS * 1e6
      local total_us=$(( NUM_CPUS * 1000000 ))
      cpu_usage=$(calc_percentage "$cpu_delta" "$total_us")
    else
      # numeric usage vs. quota
      local q_val=0
      [[ "$cpu_quota" =~ ^[0-9]+$ ]] && q_val=$cpu_quota
      if [ "$q_val" -gt 0 ]; then
        cpu_usage=$(calc_percentage "$cpu_delta" "$q_val")
      fi
    fi

    # approximate CPU cores
    local cpu_cores="0.0"
    if [ "$cpu_quota" = "max" ]; then
      cpu_cores="$NUM_CPUS"
    else
      local q_val=0
      [[ "$cpu_quota" =~ ^[0-9]+$ ]] && q_val=$cpu_quota
      local p_val=0
      [[ "$cpu_period" =~ ^[0-9]+$ ]] && p_val=$cpu_period
      if [ "$p_val" -gt 0 ] && [ "$q_val" -gt 0 ]; then
        local ratio=$(( q_val * 10 / p_val ))
        local int_part=$(( ratio / 10 ))
        local frac=$(( ratio % 10 ))
        cpu_cores="$int_part.$frac"
      fi
    fi

    # 4) Memory
    local mem_cur=0
    if [ -f "$path/memory.current" ]; then
      IFS= read -r mem_cur < "$path/memory.current"
    fi
    [[ "$mem_cur" =~ ^[0-9]+$ ]] || mem_cur=0
    local mem_used_mb=$(( mem_cur / 1024 / 1024 ))

    local mem_max_str=""
    if [ -f "$path/memory.max" ]; then
      IFS= read -r mem_max_str < "$path/memory.max"
    fi

    # fallback to numeric
    local mem_max=0
    if [[ "$mem_max_str" =~ ^[0-9]+$ ]]; then
      mem_max="$mem_max_str"
    else
      # if "max" or empty or 0 => treat as system total
      local found=0
      # read /proc/meminfo
      while IFS= read -r ln; do
        case "$ln" in
          MemTotal:\ *)
            local val="${ln#MemTotal:}"
            val="${val## }"
            val="${val%% *}"
            [[ "$val" =~ ^[0-9]+$ ]] || val=0
            mem_max=$(( val * 1024 ))
            found=1
            break
            ;;
        esac
      done < /proc/meminfo
      if [ "$found" -eq 0 ]; then
        mem_max=0
      fi
    fi

    local mem_max_mb=$(( mem_max / 1024 / 1024 ))
    local mem_percent="0.00"
    if [ "$mem_max" -gt 0 ]; then
      mem_percent=$(calc_percentage "$mem_cur" "$mem_max")
    fi

    # 5) IO
    local r2=0
    local w2=0
    if [ -f "$path/io.stat" ]; then
      while IFS= read -r ln; do
        for token in $ln; do
          case "$token" in
            rbytes=*) r2="${token#rbytes=}" ;;
            wbytes=*) w2="${token#wbytes=}" ;;
          esac
        done
      done < "$path/io.stat"
    fi
    [[ "$r2" =~ ^[0-9]+$ ]] || r2=0
    [[ "$w2" =~ ^[0-9]+$ ]] || w2=0

    local r1="${PREV_RBYTES[$cgroup]}"
    local w1="${PREV_WBYTES[$cgroup]}"
    local rd=$(( r2 - r1 ))
    local wd=$(( w2 - w1 ))
    PREV_RBYTES["$cgroup"]="$r2"
    PREV_WBYTES["$cgroup"]="$w2"

    if [ "$rd" -lt 0 ]; then rd=0; fi
    if [ "$wd" -lt 0 ]; then wd=0; fi

    local read_mb
    read_mb=$(bytes_to_mb "$rd")
    local write_mb
    write_mb=$(bytes_to_mb "$wd")
    local total_mb
    total_mb=$(bytes_to_mb $(( rd + wd )))

    # 6) processes
    local proc_cur=0
    if [ -f "$path/pids.current" ]; then
      IFS= read -r proc_cur < "$path/pids.current"
    fi
    [[ "$proc_cur" =~ ^[0-9]+$ ]] || proc_cur=0

    local proc_max_str="max"
    if [ -f "$path/pids.max" ]; then
      IFS= read -r proc_max_str < "$path/pids.max"
      [ "$proc_max_str" = "max" ] && proc_max_str="unlimited"
    fi

    # Now we either print table or the EXACT JSON structure requested
    if $JSON_MODE; then
      # Must match:
      # {
      #   "website_id":"...",
      #   "owner":"...",
      #   "cpu": {"usage":..., "cores":..., "quota":"...", "period":"..."},
      #   "memory": {"used":..., "max":..., "percentage":...},
      #   "io": {"read":..., "write":..., "total":...},
      #   "processes": {"current":..., "max":"..."}
      # }
      cat <<EOF
{
  "website_id": "$cgroup",
  "owner": "$owner",
  "cpu": {
    "usage": $cpu_usage,
    "cores": $cpu_cores,
    "quota": "$cpu_quota",
    "period": "$cpu_period"
  },
  "memory": {
    "used": $mem_used_mb,
    "max": $mem_max_mb,
    "percentage": $mem_percent
  },
  "io": {
    "read": $read_mb,
    "write": $write_mb,
    "total": $total_mb
  },
  "processes": {
    "current": $proc_cur,
    "max": "$proc_max_str"
  }
}
EOF
    else
      # Table row
      local cgrp="$cgroup"
      if [ ${#cgrp} -gt 36 ]; then
        cgrp="${cgrp:0:33}..."
      fi

      printf "%-36s | %-10s | %7s | %5s | %5d/%-5d | %6s | R:%-4sW:%-4sT:%-4s | %3d/%-5s\n" \
        "$cgrp" "$owner" "$cpu_usage%" "$cpu_cores" \
        "$mem_used_mb" "$mem_max_mb" "$mem_percent%" \
        "$read_mb" "$write_mb" "$total_mb" \
        "$proc_cur" "$proc_max_str"
    fi
  done
}

##############################################################################
# update_peak_mem: checks if current VmRSS is bigger than recorded
##############################################################################
update_peak_mem() {
  while IFS= read -r line; do
    case "$line" in
      VmRSS:*)
        local val="${line#VmRSS:}"
        val="${val## }"
        val="${val%% *}"
        [[ "$val" =~ ^[0-9]+$ ]] || val=0
        if [ "$val" -gt "$PEAK_MEM" ]; then
          PEAK_MEM="$val"
        fi
        return
        ;;
    esac
  done < /proc/self/status
}

##############################################################################
# do_display: measure iteration time if perf-test, track peak memory
##############################################################################
do_display() {
  local cgroups=("$@")

  # measure start time
  local start_time="$EPOCHREALTIME"

  # read & print stats
  read_and_display "${cgroups[@]}"

  # measure end time
  if $PERF_TEST; then
    local end_time="$EPOCHREALTIME"
    local dt
    dt=$(awk -v s="$start_time" -v e="$end_time" 'BEGIN {printf "%.6f", e - s}')
    PERF_RUNS=$((PERF_RUNS+1))
    PERF_SUM=$(awk -v a="$PERF_SUM" -v d="$dt" 'BEGIN {printf "%.6f", a + d}')

    # check memory usage => peak
    update_peak_mem
  fi
}

##############################################################################
# print_perf_summary: final summary if perf-test was used
##############################################################################
print_perf_summary() {
  if ! $PERF_TEST; then
    return
  fi
  if [ "$PERF_RUNS" -eq 0 ]; then
    return
  fi

  echo
  echo "Performance test summary:"
  echo "  Total runs: $PERF_RUNS"
  echo "  Total wall time: $PERF_SUM seconds"
  local avg
  avg=$(awk -v s="$PERF_SUM" -v r="$PERF_RUNS" 'BEGIN {printf "%.6f", s / r}')
  echo "  Average time per run: $avg seconds"

  echo "  Peak memory used by this script: ${PEAK_MEM} KB"

  # final CPU usage
  SCRIPT_CPU_END=$(get_script_cpu_ticks)
  local cpu_ticks=$(( SCRIPT_CPU_END - SCRIPT_CPU_START ))
  if [ "$cpu_ticks" -lt 0 ]; then
    cpu_ticks=0
  fi
  local cpu_secs
  cpu_secs=$(awk -v c="$cpu_ticks" -v h="$HZ" 'BEGIN {printf "%.2f", c / h}')
  local usage_pct
  usage_pct=$(awk -v c="$cpu_secs" -v w="$PERF_SUM" 'BEGIN {
    if (w <= 0) {print "0.00"}
    else {printf "%.2f", (c / w)*100}
  }')

  echo "  Script CPU time: ${cpu_secs}s / ${PERF_SUM}s (${usage_pct}%)"
}

##############################################################################
# trap_signals: let us show the summary on Ctrl+C in watch mode
##############################################################################
trap_signals() {
  print_perf_summary
  exit 0
}

trap "trap_signals" INT TERM

##############################################################################
# MAIN
##############################################################################
if $PERF_TEST; then
  # record CPU usage at start
  SCRIPT_CPU_START=$(get_script_cpu_ticks)
  # initial memory
  update_peak_mem
fi

declare -a cgroup_array=()

if $ALL_MODE; then
  mapfile -t cgroup_array < <(get_cgroup_list)
  if [ "${#cgroup_array[@]}" -eq 0 ]; then
    echo "No cgroups found in /sys/fs/cgroup/websites/."
    exit 1
  fi
else
  if [ -z "$CGROUP_SINGLE" ]; then
    interactive_select
  fi
  cgroup_array=( "$CGROUP_SINGLE" )
  if [ ! -d "/sys/fs/cgroup/websites/$CGROUP_SINGLE" ]; then
    echo "Error: '$CGROUP_SINGLE' not found in /sys/fs/cgroup/websites/."
    exit 1
  fi
fi

read_initial_stats "${cgroup_array[@]}"

if $WATCH_MODE; then
  while true; do
    sleep "$INTERVAL"
    printf "\033[H\033[J"   # clear screen
    do_display "${cgroup_array[@]}"
  done
else
  sleep "$INTERVAL"
  do_display "${cgroup_array[@]}"
  print_perf_summary
fi
