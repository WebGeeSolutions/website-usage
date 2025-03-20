#!/bin/bash

# Color Variables
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

# Function to display help message
show_help() {
    echo -e "${BLUE}Usage: $0 [OPTIONS] [website_id]${RESET}"
    echo ""
    echo "Options:"
    echo "  --help     Display this help message"
    echo "  --watch    Watch mode - continuously update stats"
    echo "  --json     Output in JSON format"
    echo ""
    echo "Example:"
    echo "  $0                    # Interactive mode - select from available websites"
    echo "  $0 abc123            # Direct mode - specify website ID"
    echo "  $0 --watch abc123    # Watch mode with specific website"
    echo "  $0 --json abc123     # JSON output for specific website"
    exit 0
}

# Function to get list of available websites
get_available_websites() {
    local websites=()
    while IFS= read -r website; do
        websites+=("$website")
    done < <(ls /sys/fs/cgroup/websites/ | grep -E '^[0-9a-f-]{36}$')
    echo "${websites[@]}"
}

# Function to display website selection menu
select_website() {
    local websites=($(get_available_websites))
    
    if [ ${#websites[@]} -eq 0 ]; then
        echo -e "${RED}No websites found.${RESET}"
        exit 1
    fi

    echo -e "${BLUE}Available Websites:${RESET}"
    echo -e "${YELLOW}----------------------------------------${RESET}"
    for i in "${!websites[@]}"; do
        local owner=$(stat -c "%U" "/var/www/${websites[$i]}" 2>/dev/null || echo "unknown")
        echo -e "${GREEN}$((i + 1)).${RESET} ${websites[$i]} (Owner: $owner)"
    done
    echo -e "${YELLOW}----------------------------------------${RESET}"
    
    while true; do
        echo -e "${BLUE}Select a website number (1-${#websites[@]}) or 'q' to quit:${RESET}"
        read -r choice
        
        if [[ "$choice" == "q" ]]; then
            exit 0
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#websites[@]} )); then
            WEBSITE_ID="${websites[$((choice - 1))]}"
            return
        else
            echo -e "${RED}Invalid selection. Please try again.${RESET}"
        fi
    done
}

# Process command-line arguments
WATCH_MODE=false
JSON_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            ;;
        --watch)
            WATCH_MODE=true
            shift
            ;;
        --json)
            JSON_MODE=true
            shift
            ;;
        *)
            if [ -z "$WEBSITE_ID" ]; then
                WEBSITE_ID="$1"
                shift
            else
                echo -e "${RED}Error: Too many arguments${RESET}"
                show_help
            fi
            ;;
    esac
done

# If no website ID provided, enter interactive mode
if [ -z "$WEBSITE_ID" ]; then
    select_website
fi

CGROUP_PATH="/sys/fs/cgroup/websites/$WEBSITE_ID"

if [ ! -d "$CGROUP_PATH" ]; then
    echo -e "${RED}Error: Website ID $WEBSITE_ID not found.${RESET}"
    exit 1
fi

# Function to get website stats
get_stats() {
    # Get CPU Quota and Period
    CPU_MAX=$(cat $CGROUP_PATH/cpu.max)
    CPU_QUOTA=$(echo $CPU_MAX | awk '{print $1}')
    CPU_PERIOD=$(echo $CPU_MAX | awk '{print $2}')

    # Calculate allocated CPU cores
    if [ "$CPU_QUOTA" == "max" ]; then
        CPU_CORES=$(nproc)
        CPU_LIMIT=$((CPU_CORES * CPU_PERIOD))
    else
        # Calculate allocated cores from quota/period
        CPU_CORES=$(echo "scale=1; $CPU_QUOTA / $CPU_PERIOD" | bc)
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

# Changed to keep divide by zero from being an issue (8Dweb)

    MEMORY_USAGE_MB=$((MEMORY_USAGE / 1024 / 1024))
    MEMORY_MAX_MB=$((MEMORY_MAX / 1024 / 1024))

    if [ "$MEMORY_MAX" -gt 0 ]; then
        MEMORY_PERCENTAGE=$(echo "scale=2; ($MEMORY_USAGE * 100) / $MEMORY_MAX" | bc)
    else
        MEMORY_PERCENTAGE=0 
    fi

    # Get Initial IO Usage
    if [ -f "$CGROUP_PATH/io.stat" ]; then
        read rbytes1 wbytes1 < <(awk '{for (i=1; i<=NF; i++) {if ($i ~ /rbytes=/) r=substr($i, 8); if ($i ~ /wbytes=/) w=substr($i, 8);}} END {print r, w}' $CGROUP_PATH/io.stat)
        rbytes1=${rbytes1:-0}
        wbytes1=${wbytes1:-0}
    else
        rbytes1=0
        wbytes1=0
    fi

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

    # Get process count
    PROC_COUNT=$(cat $CGROUP_PATH/pids.current)
    PROC_MAX=$(cat $CGROUP_PATH/pids.max)
    if [ "$PROC_MAX" == "max" ]; then
        PROC_MAX="unlimited"
    fi

    # Get website owner
    WEBSITE_OWNER=$(stat -c "%U" "/var/www/$WEBSITE_ID" 2>/dev/null || echo "unknown")

    if [ "$JSON_MODE" = true ]; then
        echo "{\"website_id\":\"$WEBSITE_ID\",\"owner\":\"$WEBSITE_OWNER\",\"cpu\":{\"usage\":$CPU_PERCENTAGE,\"cores\":$CPU_CORES,\"quota\":$CPU_QUOTA,\"period\":$CPU_PERIOD},\"memory\":{\"used\":$MEMORY_USAGE_MB,\"max\":$MEMORY_MAX_MB,\"percentage\":$MEMORY_PERCENTAGE},\"io\":{\"read\":$read_speed_mb,\"write\":$write_speed_mb,\"total\":$total_speed_mb},\"processes\":{\"current\":$PROC_COUNT,\"max\":\"$PROC_MAX\"}}"
    else
        echo -e "${YELLOW}▶ Website Information ◀${RESET}"
        echo -e "${GREEN}ID:${RESET} $WEBSITE_ID"
        echo -e "${GREEN}Owner:${RESET} $WEBSITE_OWNER"
        echo -e "${GREEN}CPU Usage:${RESET} $CPU_PERCENTAGE% (${CPU_CORES} cores)"
        echo -e "${GREEN}Memory Usage:${RESET} $MEMORY_USAGE_MB MB / $MEMORY_MAX_MB MB ($MEMORY_PERCENTAGE%)"
        echo -e "${GREEN}IO Usage:${RESET}"
        echo -e "  Read:  $read_speed_mb MB/s"
        echo -e "  Write: $write_speed_mb MB/s"
        echo -e "  Total: $total_speed_mb MB/s"
        echo -e "${GREEN}Processes:${RESET} $PROC_COUNT / $PROC_MAX"
        echo -e "${YELLOW}----------------------------------------${RESET}"
    fi
}

# Main execution
if [ "$WATCH_MODE" = true ]; then
    # Use watch command with bash to execute the script
    SCRIPT_PATH=$(readlink -f "$0")
    exec watch -n 2 -t -c "bash ${SCRIPT_PATH} $WEBSITE_ID"
else
    get_stats
fi 
