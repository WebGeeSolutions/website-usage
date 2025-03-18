#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <website_id>"
    exit 1
fi

WEBSITE_ID=$1
CGROUP_PATH="/sys/fs/cgroup/websites/$WEBSITE_ID"

if [ ! -d "$CGROUP_PATH" ]; then
    echo "Error: Website ID $WEBSITE_ID not found."
    exit 1
fi

# Get CPU Quota and Period
CPU_MAX=$(cat $CGROUP_PATH/cpu.max)
CPU_QUOTA=$(echo $CPU_MAX | awk '{print $1}')
CPU_PERIOD=$(echo $CPU_MAX | awk '{print $2}')

# Get number of CPU cores
CPU_CORES=$(nproc)

# Calculate CPU limit
if [ "$CPU_QUOTA" == "max" ]; then
    CPU_LIMIT=$((CPU_CORES * CPU_PERIOD))
else
    CPU_LIMIT=$CPU_QUOTA
fi

# Get initial CPU usage
PREV_CPU_USAGE=$(awk '/usage_usec/ {print $2}' $CGROUP_PATH/cpu.stat)
sleep 1
CURR_CPU_USAGE=$(awk '/usage_usec/ {print $2}' $CGROUP_PATH/cpu.stat)

# Calculate CPU usage percentage
CPU_DELTA=$((CURR_CPU_USAGE - PREV_CPU_USAGE))
CPU_PERCENTAGE=$(echo "scale=2; ($CPU_DELTA * 100) / $CPU_LIMIT" | bc)

# Get Memory Usage
MEMORY_USAGE=$(cat $CGROUP_PATH/memory.current)
MEMORY_MAX=$(cat $CGROUP_PATH/memory.max)
if [ "$MEMORY_MAX" == "max" ]; then
    MEMORY_MAX=$(grep MemTotal /proc/meminfo | awk '{print $2 * 1024}')
fi
MEMORY_USAGE_MB=$((MEMORY_USAGE / 1024 / 1024))
MEMORY_MAX_MB=$((MEMORY_MAX / 1024 / 1024))
MEMORY_PERCENTAGE=$(echo "scale=2; ($MEMORY_USAGE / $MEMORY_MAX) * 100" | bc)

# Get Initial IO Usage
if [ -f "$CGROUP_PATH/io.stat" ]; then
    read rbytes1 wbytes1 < <(awk '{for (i=1; i<=NF; i++) {if ($i ~ /rbytes=/) r=substr($i, 8); if ($i ~ /wbytes=/) w=substr($i, 8);}} END {print r, w}' $CGROUP_PATH/io.stat)
    rbytes1=${rbytes1:-0}
    wbytes1=${wbytes1:-0}
else
    rbytes1=0
    wbytes1=0
fi

# Wait for 1 second
sleep 1

# Get Final IO Usage
if [ -f "$CGROUP_PATH/io.stat" ]; then
    read rbytes2 wbytes2 < <(awk '{for (i=1; i<=NF; i++) {if ($i ~ /rbytes=/) r=substr($i, 8); if ($i ~ /wbytes=/) w=substr($i, 8);}} END {print r, w}' $CGROUP_PATH/io.stat)
    rbytes2=${rbytes2:-0}
    wbytes2=${wbytes2:-0}
else
    rbytes2=0
    wbytes2=0
fi

# Calculate IO Usage in Bytes per second
read_speed=$((rbytes2 - rbytes1))
write_speed=$((wbytes2 - wbytes1))
total_speed=$((read_speed + write_speed))

# Convert to MB/s
read_speed_mb=$(echo "scale=2; $read_speed / 1024 / 1024" | bc)
write_speed_mb=$(echo "scale=2; $write_speed / 1024 / 1024" | bc)
total_speed_mb=$(echo "scale=2; $total_speed / 1024 / 1024" | bc)

# Output results
echo "Website ID: $WEBSITE_ID"
echo "CPU Usage: $CPU_PERCENTAGE%"
echo "Memory Usage: $MEMORY_USAGE_MB MB / $MEMORY_MAX_MB MB ($MEMORY_PERCENTAGE%)"
echo "IO Usage: Read $read_speed_mb MB/s, Write $write_speed_mb MB/s, Total $total_speed_mb MB/s"
