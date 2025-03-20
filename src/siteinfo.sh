#!/bin/bash

# Color Variables
RED="\e[31m"
GREEN="\e[32m"
RESET="\e[0m"

# Default directories
WWW_DIR="/var/www"

# Default sorting mode (CPU, Memory, IO)
SORT_MODE="cpu"

# Function to display help message
show_help() {
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --UUID <uuid>      Monitor a specific website using its UUID."
    echo "  --OWNER <name>     Find and monitor websites owned by a user."
    echo "  --ALL              Monitor all websites."
    echo "  --SORT <cpu|mem|io> Sort by CPU (default), memory, or IO."
    echo "  --HELP             Display this help message and exit."
    echo ""
    exit 0
}

# Process command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --UUID)
            UUID="$2"
            shift 2
            ;;
        --OWNER)
            OWNER="$2"
            shift 2
            ;;
        --ALL)
            MONITOR_ALL=true
            shift
            ;;
        --SORT)
            SORT_MODE="${2,,}" # Convert to lowercase
            shift 2
            ;;
        --HELP)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${RESET}"
            show_help
            ;;
    esac
done

# Validate sorting mode and set sorting flag for systemd-cgtop
case "$SORT_MODE" in
    cpu) SORT_FLAG="" ;;
    mem) SORT_FLAG="-m" ;;
    io) SORT_FLAG="-i" ;;
    *)
        echo -e "${RED}Error: Invalid sorting option. Use 'cpu', 'mem', or 'io'.${RESET}"
        exit 1
        ;;
esac

# Function to check if UUID exists in /var/www
validate_uuid() {
    local uuid="$1"
    if [[ ! -d "$WWW_DIR/$uuid" ]]; then
        echo -e "${RED}Error: Website ID $uuid not found in /var/www.${RESET}"
        exit 1
    fi
}

# Function to find UUIDs by owner (Now Supports Partial Search)
find_uuid_by_owner() {
    local search_owner="$1"
    local found_users=()
    local found_uuids=()

    # Find all unique users who own directories in /var/www
    while IFS= read -r user; do
        found_users+=("$user")
    done < <(find "$WWW_DIR" -maxdepth 1 -mindepth 1 -type d -exec stat -c "%U" {} + | sort | uniq | grep -i "$search_owner")

    if [[ ${#found_users[@]} -eq 0 ]]; then
        echo -e "${RED}No users found matching '${search_owner}'.${RESET}"
        exit 1
    elif [[ ${#found_users[@]} -gt 1 ]]; then
        echo -e "${GREEN}Multiple users found matching '${search_owner}':${RESET}"
        for i in "${!found_users[@]}"; do
            echo "$((i + 1)). ${found_users[$i]}"
        done
        echo ""
        echo -e "${GREEN}Select a user number:${RESET}"
        read -r user_choice
        if [[ ! "$user_choice" =~ ^[0-9]+$ ]] || (( user_choice < 1 || user_choice > ${#found_users[@]} )); then
            echo -e "${RED}Invalid selection.${RESET}"
            exit 1
        fi
        OWNER="${found_users[$((user_choice - 1))]}"
    else
        OWNER="${found_users[0]}"
    fi

    # Find all UUID directories owned by the selected user
    while IFS= read -r dir; do
        UUID=$(basename "$dir")
        found_uuids+=("$UUID")
    done < <(find "$WWW_DIR" -maxdepth 1 -mindepth 1 -type d -exec stat -c "%U %n" {} + | awk -v user="$OWNER" '$1 == user {print $2}')

    if [[ ${#found_uuids[@]} -eq 0 ]]; then
        echo -e "${RED}No websites found for user '${OWNER}'.${RESET}"
        exit 1
    fi

    echo -e "${GREEN}Found websites owned by ${OWNER}:${RESET}"
    for i in "${!found_uuids[@]}"; do
        echo "$((i + 1)). ${found_uuids[$i]}"
    done

    echo ""
    echo -e "${GREEN}Select a website number to monitor:${RESET}"
    read -r choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#found_uuids[@]} )); then
        echo -e "${RED}Invalid selection.${RESET}"
        exit 1
    fi

    UUID="${found_uuids[$((choice - 1))]}"
}

# Handle command-line UUID monitoring
if [[ -n "$UUID" ]]; then
    validate_uuid "$UUID"
    echo -e "${GREEN}Monitoring website: $UUID${RESET}"
    exec systemd-cgtop -p $SORT_FLAG -n 0 --depth=1 "/websites/$UUID"
fi

# Handle command-line owner search
if [[ -n "$OWNER" ]]; then
    find_uuid_by_owner "$OWNER"
    validate_uuid "$UUID"
    echo -e "${GREEN}Monitoring website: $UUID${RESET}"
    exec systemd-cgtop -p $SORT_FLAG -n 0 --depth=1 "/websites/$UUID"
fi

# Handle command-line all websites monitoring
if [[ "$MONITOR_ALL" == true ]]; then
    echo -e "${GREEN}Monitoring all websites, sorted by $SORT_MODE${RESET}"
    exec systemd-cgtop -p $SORT_FLAG -n 0 --depth=1 /websites/
fi

# Interactive Mode (if no arguments)
echo ""
echo "**************************************************************"
echo "*   Do you want to monitor all websites or a specific one?   *"
echo "*                                                            *"
echo "*   Type 1 for UUID Search                                   *"
echo "*   Type 2 for Directory Owner Search                        *"
echo "*   Type 3 to Monitor All Websites                           *"
echo "*                                                            *"
echo "**************************************************************"
echo ""
read -r SEARCH_TYPE

case "$SEARCH_TYPE" in
    1)
        echo ""
        echo "Enter full UUID:"
        read -r UUID
        validate_uuid "$UUID"
        echo -e "${GREEN}Monitoring website: $UUID${RESET}"
        exec systemd-cgtop -p $SORT_FLAG -n 0 --depth=1 "/websites/$UUID"
        ;;
    2)
        echo ""
        echo "Enter at least 3 characters of the directory owner's username:"
        read -r OWNER
        find_uuid_by_owner "$OWNER"
        validate_uuid "$UUID"
        echo -e "${GREEN}Monitoring website: $UUID${RESET}"
        exec systemd-cgtop -p $SORT_FLAG -n 0 --depth=1 "/websites/$UUID"
        ;;
    3)
        echo -e "${GREEN}Monitoring all websites, sorted by $SORT_MODE${RESET}"
        exec systemd-cgtop -p $SORT_FLAG -n 0 --depth=1 /websites/
        ;;
    *)
        echo -e "${RED}Invalid selection. Exiting...${RESET}"
        exit 1
        ;;
esac