#!/bin/bash

# Color Variables
RED="\e[31m"
GREEN="\e[32m"
RESET="\e[0m"

# Directory containing website UUIDs
WWW_DIR="/var/www"
CGROUP_BASE="/sys/fs/cgroup/websites"

# Default: Do NOT calculate CPU percentage
CALCULATE_CPU_PERCENTAGE=false

# Check for `--CPU` flag
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

    OWNER=$(stat -c "%U" "$WWW_DIR/$UUID" 2>/dev/null)

    # Get CPU Quota and Period
    CPU_MAX=$(cat "$CGROUP_PATH/cpu.max" 2>/dev/null)
    CPU_QUOTA=$(echo "$CPU_MAX" | awk '{print $1}')
    CPU_PERIOD=$(echo "$CPU_MAX" | awk '{print $2}')
    CPU_CORES=$(nproc)

    # Determine CPU Limit and Status
    if [ "$CPU_QUOTA" == "max" ]; then
        CPU_LIMIT="UNLIMITED"
        CPU_PERCENTAGE="UNLIMITED"
    else
        CPU_LIMIT=$(( CPU_QUOTA / CPU_PERIOD * CPU_CORES ))
    fi

    # Calculate CPU Usage (if enabled)
    if [ "$CALCULATE_CPU_PERCENTAGE" = true ] && [ "$CPU_LIMIT" != "UNLIMITED" ]; then
        PREV_CPU_USAGE=$(awk '/usage_usec/ {print $2}' "$CGROUP_PATH/cpu.stat" 2>/dev/null)
        sleep 1
        CURR_CPU_USAGE=$(awk '/usage_usec/ {print $2}' "$CGROUP_PATH/cpu.stat" 2>/dev/null)

        if [[ -n "$PREV_CPU_USAGE" && -n "$CURR_CPU_USAGE" && "$CURR_CPU_USAGE" -ge "$PREV_CPU_USAGE" ]]; then
            CPU_DELTA=$((CURR_CPU_USAGE - PREV_CPU_USAGE))
            CPU_PERCENTAGE=$(echo "scale=2; ($CPU_DELTA * 100) / ($CPU_LIMIT * 1000)" | bc 2>/dev/null)
        else
            CPU_PERCENTAGE="0"
        fi
    elif [ "$CPU_LIMIT" != "UNLIMITED" ]; then
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
echo "--------------------------------------"
echo "Website ID: $UUID"
echo "Owner: $OWNER"
echo "CPU Usage: ${CPU_PERCENTAGE}%"
echo "Memory Usage: $MEMORY_USAGE_MB MB / $MEMORY_MAX_MB MB ($MEMORY_PERCENTAGE%)"
echo "I/O Read Speed: ${read_speed_mb} MB/s"
echo "I/O Write Speed: ${write_speed_mb} MB/s"
echo "I/O Total Speed: ${total_speed_mb} MB/s"
echo "--------------------------------------"
}

# Handle command-line arguments
if [[ "$1" == "--UUID" && -n "$2" ]]; then
    process_website "$2"
    exit 0
elif [[ "$1" == "--OWNER" && -n "$2" ]]; then
    echo "Searching for websites owned by: ${2}"

    UUID_MATCHES=$(find "$WWW_DIR" -maxdepth 1 -type d -exec stat -c "%U %n" {} + | awk -v term="$2" '$1 ~ term {print $2}' | xargs -n1 basename)

    if [[ -z "$UUID_MATCHES" ]]; then
        echo -e "${RED}No matches found for owner '${2}'. Exiting...${RESET}"
        exit 1
    fi

    for UUID in $UUID_MATCHES; do
        process_website "$UUID"
    done
    exit 0
elif [[ "$1" == "--ALL" ]]; then
    for UUID in $(ls "$WWW_DIR"); do
        process_website "$UUID"
    done
    exit 0
fi

# If no arguments, enter interactive mode
echo ""
echo "**************************************************************"
echo "*   Do you want to include CPU usage percentage? (y/n)      *"
echo "**************************************************************"
echo ""
read -r CPU_CHOICE
if [[ "$CPU_CHOICE" == "y" || "$CPU_CHOICE" == "Y" ]]; then
    CALCULATE_CPU_PERCENTAGE=true
fi

echo ""
echo "**************************************************************"
echo "*   Please select an option:                                 *"
echo "*                                                            *"
echo "*   Type 1 for UUID Search                                   *"
echo "*   Type 2 for Directory Owner Search                        *"
echo "*   Type 3 to List All Sites                                 *"
echo "*                                                            *"
echo "**************************************************************"
echo ""

read -r SEARCH_TYPE

if [ "$SEARCH_TYPE" == "1" ]; then
    echo ""
    echo "Enter full UUID:"
    read -r SEARCH_TERM
    process_website "$SEARCH_TERM"
elif [ "$SEARCH_TYPE" == "2" ]; then
    echo ""
    echo "Enter at least 4-5 characters of the directory owner:"
    read -r SEARCH_TERM
    echo "Searching for websites owned by: ${SEARCH_TERM}"

    UUID_MATCHES=$(find "$WWW_DIR" -maxdepth 1 -type d -exec stat -c "%U %n" {} + | awk -v term="$SEARCH_TERM" '$1 ~ term {print $2}' | xargs -n1 basename)

    if [[ -z "$UUID_MATCHES" ]]; then
        echo -e "${RED}No matches found for owner '${SEARCH_TERM}'. Exiting...${RESET}"
        exit 1
    fi

    for UUID in $UUID_MATCHES; do
        process_website "$UUID"
    done
elif [ "$SEARCH_TYPE" == "3" ]; then
    echo ""
    echo "Listing all sites..."
    for UUID in $(ls "$WWW_DIR"); do
        process_website "$UUID"
    done
else
    echo -e "${RED}Invalid selection. Exiting...${RESET}"
    exit 1
fi
