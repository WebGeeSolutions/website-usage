#!/bin/bash

# Color Variables
RED="\e[31m"
GREEN="\e[32m"
RESET="\e[0m"

# Temporary files for sorting CPU, Memory, and IO usage
CPU_TEMP_FILE=$(mktemp)
MEM_TEMP_FILE=$(mktemp)
IO_TEMP_FILE=$(mktemp)

# Directory containing website UUIDs
WWW_DIR="/var/www"
CGROUP_BASE="/sys/fs/cgroup/websites"

# Default: **DO NOT** calculate CPU percentage
CALCULATE_CPU_PERCENTAGE=false

# Check if `--CPU` flag is present
for arg in "$@"; do
    if [[ "$arg" == "--CPU" ]]; then
        CALCULATE_CPU_PERCENTAGE=true
    fi
done

# Function to process a website
process_website() {
    UUID=$1
    CGROUP_PATH="$CGROUP_BASE/$UUID"
    
    if [ ! -d "$CGROUP_PATH" ]; then
        echo -e "${RED}Error: Website ID $UUID not found in cgroup. Skipping.${RESET}"
        return
    fi

    # Get directory owner
    OWNER=$(stat -c "%U" "$WWW_DIR/$UUID" 2>/dev/null)

    # Get CPU Quota and Period
    CPU_MAX=$(cat $CGROUP_PATH/cpu.max 2>/dev/null)
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

    # Calculate CPU Usage (if enabled)
    if [ "$CALCULATE_CPU_PERCENTAGE" = true ]; then
        PREV_CPU_USAGE=$(awk '/usage_usec/ {print $2}' "$CGROUP_PATH/cpu.stat" 2>/dev/null)
        sleep 1
        CURR_CPU_USAGE=$(awk '/usage_usec/ {print $2}' "$CGROUP_PATH/cpu.stat" 2>/dev/null)

        if [[ -n "$PREV_CPU_USAGE" && -n "$CURR_CPU_USAGE" && "$CURR_CPU_USAGE" -ge "$PREV_CPU_USAGE" ]]; then
            CPU_DELTA=$((CURR_CPU_USAGE - PREV_CPU_USAGE))
            CPU_PERCENTAGE=$(echo "scale=2; ($CPU_DELTA * 100) / $CPU_LIMIT" | bc 2>/dev/null)
        else
            CPU_PERCENTAGE="0.00"
        fi
    else
        CPU_PERCENTAGE="N/A"
    fi

    # Get Memory Usage
    MEMORY_USAGE=$(cat "$CGROUP_PATH/memory.current" 2>/dev/null)
    MEMORY_MAX=$(cat "$CGROUP_PATH/memory.max" 2>/dev/null)
    if [ "$MEMORY_MAX" == "max" ]; then
        MEMORY_MAX=$(grep MemTotal /proc/meminfo | awk '{print $2 * 1024}')
    fi
    MEMORY_USAGE_MB=$((MEMORY_USAGE / 1024 / 1024))
    MEMORY_MAX_MB=$((MEMORY_MAX / 1024 / 1024))
    MEMORY_PERCENTAGE=$(echo "scale=2; ($MEMORY_USAGE / $MEMORY_MAX) * 100" | bc 2>/dev/null)

    # Get Initial IO Usage
    if [ -f "$CGROUP_PATH/io.stat" ]; then
        read rbytes1 wbytes1 < <(awk '{for (i=1; i<=NF; i++) {if ($i ~ /rbytes=/) r=substr($i, 8); if ($i ~ /wbytes=/) w=substr($i, 8);}} END {print r, w}' "$CGROUP_PATH/io.stat")
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
        read rbytes2 wbytes2 < <(awk '{for (i=1; i<=NF; i++) {if ($i ~ /rbytes=/) r=substr($i, 8); if ($i ~ /wbytes=/) w=substr($i, 8);}} END {print r, w}' "$CGROUP_PATH/io.stat")
        rbytes2=${rbytes2:-0}
        wbytes2=${wbytes2:-0}
    else
        rbytes2=0
        wbytes2=0
    fi

    # Calculate IO Usage
    READ_IO_MB=$(( (rbytes2 - rbytes1) / 1024 / 1024 ))
    WRITE_IO_MB=$(( (wbytes2 - wbytes1) / 1024 / 1024 ))

    # Store CPU, memory, and IO usage in temporary files
    echo "$UUID $OWNER $CPU_PERCENTAGE%" >> "$CPU_TEMP_FILE"
    echo "$UUID $OWNER $MEMORY_USAGE_MB MB" >> "$MEM_TEMP_FILE"
    echo "$UUID $OWNER Read: ${READ_IO_MB}MB/s Write: ${WRITE_IO_MB}MB/s" >> "$IO_TEMP_FILE"

    # Output results
    echo "--------------------------------------"
    echo "Website ID: $UUID"
    echo "Owner: $OWNER"
    echo "CPU Usage: ${CPU_PERCENTAGE}%"
    echo "Memory Usage: $MEMORY_USAGE_MB MB / $MEMORY_MAX_MB MB ($MEMORY_PERCENTAGE%)"
    echo "IO Usage: Read: ${READ_IO_MB}MB/s | Write: ${WRITE_IO_MB}MB/s"
    echo "--------------------------------------"
}

# Handle command-line arguments
if [[ "$1" == "--UUID" && -n "$2" ]]; then
    SEARCH_TERM="$2"
    process_website "$SEARCH_TERM"
    exit 0
elif [[ "$1" == "--OWNER" && -n "$2" ]]; then
    SEARCH_TERM="$2"
    UUID_MATCHES=$(find "$WWW_DIR" -maxdepth 1 -type d -exec stat -c "%U %n" {} + | awk -v term="$SEARCH_TERM" '$1 ~ term {print $2}')
    for UUID in $UUID_MATCHES; do
        process_website "$(basename "$UUID")"
    done
    exit 0
elif [[ "$1" == "--ALL" ]]; then
    for UUID in $(ls "$WWW_DIR"); do
        process_website "$UUID"
    done
    exit 0
fi

# If no arguments, enter interactive mode
echo "***************************************************************************************"
echo "*   Do you want to include CPU usage percentage in the output? (y/n)                 *"
echo "***************************************************************************************"
read CPU_CHOICE
if [[ "$CPU_CHOICE" == "y" || "$CPU_CHOICE" == "Y" ]]; then
    CALCULATE_CPU_PERCENTAGE=true
fi

echo "***************************************************************************************"
echo "*   Do you want to check one/several websites or all websites?                        *"
echo "*   Type 1 to search by UUID/User for 'one/several' sites                             *"
echo "*   Type 2 to output 'all' sites                                                      *"
echo "***************************************************************************************"

read MODE
if [ "$MODE" == "1" ]; then
    echo "Enter UUID or Directory Owner:"
    read SEARCH_TERM
    process_website "$SEARCH_TERM"
else
    for UUID in $(ls "$WWW_DIR"); do
        process_website "$UUID"
    done
fi
