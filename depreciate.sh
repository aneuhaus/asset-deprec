#!/bin/bash

# Asset Depreciation Calculator
# Usage: ./depreciate.sh [yaml_file]

# Configuration
YAML_FILE="assets.yaml"
SHOW_MONTHLY=false
START_DATE=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -m) SHOW_MONTHLY=true; shift ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) 
            if [[ -z "$START_DATE" && "$1" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
                START_DATE="$1"
            else
                YAML_FILE="$1"
            fi
            shift ;;
    esac
done

# Default START_DATE to current month if not provided
if [[ -z "$START_DATE" ]]; then
    START_DATE=$(date "+%Y-%m")
fi

# Check for dependencies
if ! command -v yq &> /dev/null; then
    echo "Error: 'yq' is not installed. Please install it to run this script."
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo "Error: 'bc' is not installed. Please install it to run this script."
    exit 1
fi

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: File '$YAML_FILE' not found."
    exit 1
fi

# Colors
BOLD='\033[1m'
BLUE='\033[34m'
GREEN='\033[32m'
CYAN='\033[36m'
NC='\033[0m'

format_num() {
    local val=$1
    if [[ $val == .* ]]; then echo "0$val"; elif [[ $val == -.* ]]; then echo "-0${val:1}"; else echo "$val"; fi
}

# Function to get date for month offset
get_date_label() {
    local offset=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS date syntax
        date -v+"$offset"m -j -f "%Y-%m" "$START_DATE" "+%b %Y"
    else
        # Linux/GNU date syntax
        date -d "$START_DATE-01 + $offset months" "+%b %Y"
    fi
}

num_assets=$(yq '.assets | length' "$YAML_FILE")

declare -a monthly_totals
max_months=0

echo -e "${BOLD}${BLUE}================================================================================${NC}"
echo -e "${BOLD}${BLUE}                           ASSET DEPRECIATION REPORT                            ${NC}"
echo -e "${BOLD}${BLUE}================================================================================${NC}"

for ((i=0; i<$num_assets; i++)); do
    name=$(yq ".assets[$i].name" "$YAML_FILE")
    value=$(yq ".assets[$i].value" "$YAML_FILE")
    lifespan=$(yq ".assets[$i].lifespan" "$YAML_FILE")
    mode=$(yq ".assets[$i].mode // \"Straight-Line\"" "$YAML_FILE")
    salvage=$(yq ".assets[$i].salvage_value // 0" "$YAML_FILE")

    asset_months=$((lifespan * 12))
    if [ "$asset_months" -gt "$max_months" ]; then max_months=$asset_months; fi

    echo -e "${BOLD}Asset:${NC} ${GREEN}$name${NC}"
    echo -e "${CYAN}Initial Value:${NC} \$$value | ${CYAN}Lifespan:${NC} $lifespan yrs | ${CYAN}Mode:${NC} $mode | ${CYAN}Salvage:${NC} \$$salvage"
    echo "--------------------------------------------------------------------------------"
    printf "${BOLD}%-6s | %-16s | %-16s${NC}\n" "Year" "Depreciation" "Book Value"
    echo "-------|------------------|------------------"

    current_value=$value
    
    if [[ "$mode" == "Straight-Line" ]]; then
        annual_dep=$(echo "scale=4; ($value - $salvage) / $lifespan" | bc)
        for ((year=1; year<=$lifespan; year++)); do
            if [ "$year" -eq "$lifespan" ]; then
                dep=$(echo "scale=2; $current_value - $salvage" | bc)
            else
                dep=$(echo "scale=2; $annual_dep / 1" | bc)
            fi
            
            monthly_val=$(echo "scale=4; $dep / 12" | bc)
            for ((m=0; m<12; m++)); do
                idx=$(( (year-1)*12 + m ))
                monthly_totals[$idx]=$(echo "${monthly_totals[$idx]:-0} + $monthly_val" | bc)
            done

            next_value=$(echo "scale=4; $current_value - $dep" | bc)
            printf "%-6d | %16.2f | %16.2f\n" "$year" "$(format_num $dep)" "$(format_num $next_value)"
            current_value=$next_value
        done
    elif [[ "$mode" == "Declining Balance" ]]; then
        rate=$(echo "scale=4; 2 / $lifespan" | bc)
        for ((year=1; year<=$lifespan; year++)); do
            raw_dep=$(echo "scale=4; $current_value * $rate" | bc)
            remaining_to_salvage=$(echo "scale=4; $current_value - $salvage" | bc)
            is_over=$(echo "$raw_dep > $remaining_to_salvage" | bc)
            if [ "$is_over" -eq 1 ]; then dep=$remaining_to_salvage; else dep=$raw_dep; fi
            
            monthly_val=$(echo "scale=4; $dep / 12" | bc)
            for ((m=0; m<12; m++)); do
                idx=$(( (year-1)*12 + m ))
                monthly_totals[$idx]=$(echo "${monthly_totals[$idx]:-0} + $monthly_val" | bc)
            done

            next_value=$(echo "scale=4; ($current_value - $dep)" | bc)
            display_dep=$(echo "scale=2; $dep / 1" | bc)
            display_value=$(echo "scale=2; $next_value / 1" | bc)
            printf "%-6d | %16.2f | %16.2f\n" "$year" "$(format_num $display_dep)" "$(format_num $display_value)"
            current_value=$next_value
            is_at_salvage=$(echo "$current_value <= $salvage" | bc)
            if [ "$is_at_salvage" -eq 1 ]; then
                for ((next_year=year+1; next_year<=$lifespan; next_year++)); do
                     printf "%-6d | %16.2f | %16.2f\n" "$next_year" "0.00" "$(format_num $salvage)"
                done
                break
            fi
        done
    fi
    echo -e "${BLUE}================================================================================${NC}\n"
done

# Print Overall Monthly Summary if -m is passed
if [ "$SHOW_MONTHLY" = true ]; then
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
    echo -e "${BOLD}${BLUE}                     OVERALL MONTHLY DEPRECIATION SCHEDULE                      ${NC}"
    echo -e "${BOLD}${BLUE}================================================================================${NC}"
    printf "${BOLD}%-20s | %-14s | %-16s${NC}\n" "Period" "Monthly Dep." "Annualized Dep."
    echo "---------------------|----------------|------------------"

    start_idx=0
    while [ $start_idx -lt $max_months ]; do
        current_val=${monthly_totals[$start_idx]:-0}
        current_display=$(echo "scale=2; $current_val / 1" | bc)
        
        # Find how many consecutive months have the same value
        end_idx=$start_idx
        while [ $end_idx -lt $max_months ]; do
            next_val=${monthly_totals[$((end_idx+1))]:-0}
            next_display=$(echo "scale=2; $next_val / 1" | bc)
            if [[ "$next_display" != "$current_display" ]]; then
                break
            fi
            end_idx=$((end_idx + 1))
        done

        # Format label
        start_label=$(get_date_label $start_idx)
        if [ $start_idx -eq $end_idx ]; then
            period_label="$start_label"
        else
            end_label=$(get_date_label $end_idx)
            # If start and end are in the same year, we can abbreviate (optional)
            period_label="$start_label - $end_label"
        fi

        annualized=$(echo "scale=2; $current_val * 12" | bc)
        printf "%-20s | %14.2f | %16.2f\n" "$period_label" "$(format_num $current_display)" "$(format_num $annualized)"
        
        start_idx=$((end_idx + 1))
    done
    echo -e "${BLUE}================================================================================${NC}"
fi

