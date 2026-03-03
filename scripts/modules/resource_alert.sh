#!/bin/bash
# ================================================================
#  Module: Resource Alerts — RAM/Disk/CPU monitoring → Telegram
#  Runs via cron every 5 minutes with 30-min cooldown on alerts
# ================================================================

ALERT_CONFIG="/root/.vps-config/resource_alert.conf"
ALERT_COOLDOWN_FILE="/tmp/.resource_alert_cooldown"
ALERT_COOLDOWN_SECONDS=1800  # 30 minutes

# ── Default thresholds ──
ALERT_RAM_THRESHOLD=90
ALERT_DISK_THRESHOLD=85
ALERT_CPU_THRESHOLD=95
ALERT_SWAP_THRESHOLD=80

# Load custom thresholds if available
[ -f "$ALERT_CONFIG" ] && source "$ALERT_CONFIG"

# ── Send Telegram alert ──
_alert_telegram() {
    local msg="$1"
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return
    curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=$msg" -d "parse_mode=HTML" >/dev/null 2>&1
}

# ── Check cooldown (prevent alert spam) ──
_alert_check_cooldown() {
    local alert_type="$1"
    local cooldown_key="${ALERT_COOLDOWN_FILE}_${alert_type}"
    if [ -f "$cooldown_key" ]; then
        local last=$(cat "$cooldown_key" 2>/dev/null)
        local now=$(date +%s)
        local diff=$((now - ${last:-0}))
        [ $diff -lt $ALERT_COOLDOWN_SECONDS ] && return 1
    fi
    date +%s > "$cooldown_key"
    return 0
}

# ── Main resource check (for cron) ──
resource_check() {
    local hostname=$(hostname -s 2>/dev/null || echo "vps")
    local alerts=""

    # RAM check
    local ram_total=$(free | awk '/Mem:/ {print $2}')
    local ram_used=$(free | awk '/Mem:/ {print $3}')
    local ram_pct=0
    [ "$ram_total" -gt 0 ] 2>/dev/null && ram_pct=$((ram_used * 100 / ram_total))

    if [ "$ram_pct" -ge "$ALERT_RAM_THRESHOLD" ]; then
        if _alert_check_cooldown "ram"; then
            local ram_h=$(free -h | awk '/Mem:/ {printf "%s/%s", $3, $2}')
            alerts="${alerts}🔴 RAM: ${ram_pct}% (${ram_h})\n"
        fi
    fi

    # Disk check
    local disk_pct=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
    if [ "${disk_pct:-0}" -ge "$ALERT_DISK_THRESHOLD" ]; then
        if _alert_check_cooldown "disk"; then
            local disk_h=$(df -h / | awk 'NR==2 {printf "%s/%s", $3, $2}')
            alerts="${alerts}🔴 Disk: ${disk_pct}% (${disk_h})\n"
        fi
    fi

    # CPU check (1-min load avg vs cores)
    local cpu_cores=$(nproc 2>/dev/null || echo 1)
    local load_1m=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}')
    local cpu_pct=0
    if [ -n "$load_1m" ] && [ "$cpu_cores" -gt 0 ]; then
        cpu_pct=$(awk "BEGIN {printf \"%d\", ($load_1m / $cpu_cores) * 100}")
    fi
    if [ "$cpu_pct" -ge "$ALERT_CPU_THRESHOLD" ]; then
        if _alert_check_cooldown "cpu"; then
            alerts="${alerts}🔴 CPU: ${cpu_pct}% (load: ${load_1m}, ${cpu_cores} cores)\n"
        fi
    fi

    # Swap check
    local swap_total=$(free | awk '/Swap:/ {print $2}')
    if [ "${swap_total:-0}" -gt 0 ]; then
        local swap_used=$(free | awk '/Swap:/ {print $3}')
        local swap_pct=$((swap_used * 100 / swap_total))
        if [ "$swap_pct" -ge "$ALERT_SWAP_THRESHOLD" ]; then
            if _alert_check_cooldown "swap"; then
                local swap_h=$(free -h | awk '/Swap:/ {printf "%s/%s", $3, $2}')
                alerts="${alerts}🟡 Swap: ${swap_pct}% (${swap_h})\n"
            fi
        fi
    fi

    # Send alert if any
    if [ -n "$alerts" ]; then
        local msg="⚠️ <b>[$hostname] Resource Alert</b>\n\n${alerts}\nTime: $(date '+%H:%M %d/%m/%Y')"
        _alert_telegram "$msg"
        echo -e "$msg"
    fi
}

# ── Show current resources ──
resource_status() {
    echo ""
    echo -e "${BOLD}  📊 Resource Status${NC}"
    echo ""

    local ram_total=$(free -h | awk '/Mem:/ {print $2}')
    local ram_used=$(free -h | awk '/Mem:/ {print $3}')
    local ram_pct=$(free | awk '/Mem:/ {printf "%d", $3/$2*100}')
    local ram_color="$GREEN"
    [ "$ram_pct" -ge 70 ] && ram_color="$YELLOW"
    [ "$ram_pct" -ge "$ALERT_RAM_THRESHOLD" ] && ram_color="$RED"
    echo -e "  RAM:  ${ram_color}${ram_pct}%${NC} (${ram_used}/${ram_total}) — threshold: ${ALERT_RAM_THRESHOLD}%"

    local disk_pct=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
    local disk_h=$(df -h / | awk 'NR==2 {printf "%s/%s", $3, $2}')
    local disk_color="$GREEN"
    [ "${disk_pct:-0}" -ge 70 ] && disk_color="$YELLOW"
    [ "${disk_pct:-0}" -ge "$ALERT_DISK_THRESHOLD" ] && disk_color="$RED"
    echo -e "  Disk: ${disk_color}${disk_pct}%${NC} (${disk_h}) — threshold: ${ALERT_DISK_THRESHOLD}%"

    local cpu_cores=$(nproc 2>/dev/null || echo 1)
    local load_1m=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}')
    local cpu_pct=0
    [ -n "$load_1m" ] && cpu_pct=$(awk "BEGIN {printf \"%d\", ($load_1m / $cpu_cores) * 100}")
    local cpu_color="$GREEN"
    [ "$cpu_pct" -ge 70 ] && cpu_color="$YELLOW"
    [ "$cpu_pct" -ge "$ALERT_CPU_THRESHOLD" ] && cpu_color="$RED"
    echo -e "  CPU:  ${cpu_color}${cpu_pct}%${NC} (load: ${load_1m}, ${cpu_cores} cores) — threshold: ${ALERT_CPU_THRESHOLD}%"

    local swap_total=$(free | awk '/Swap:/ {print $2}')
    if [ "${swap_total:-0}" -gt 0 ]; then
        local swap_pct=$(free | awk '/Swap:/ {printf "%d", $3/$2*100}')
        local swap_h=$(free -h | awk '/Swap:/ {printf "%s/%s", $3, $2}')
        local swap_color="$GREEN"
        [ "$swap_pct" -ge 50 ] && swap_color="$YELLOW"
        [ "$swap_pct" -ge "$ALERT_SWAP_THRESHOLD" ] && swap_color="$RED"
        echo -e "  Swap: ${swap_color}${swap_pct}%${NC} (${swap_h}) — threshold: ${ALERT_SWAP_THRESHOLD}%"
    else
        echo -e "  Swap: ${YELLOW}Not configured${NC}"
    fi

    echo ""
    # Top 5 processes by memory
    echo -e "  ${WHITE}Top 5 by RAM:${NC}"
    ps aux --sort=-%mem 2>/dev/null | head -6 | tail -5 | awk '{printf "    %-10s %5s%% %s\n", $1, $4, $11}'
    pause
}

# ── Configure thresholds ──
resource_config() {
    echo ""
    echo -e "${BOLD}  ⚙️ Alert Thresholds${NC}"
    echo ""
    echo -e "  Current: RAM=${ALERT_RAM_THRESHOLD}% Disk=${ALERT_DISK_THRESHOLD}% CPU=${ALERT_CPU_THRESHOLD}% Swap=${ALERT_SWAP_THRESHOLD}%"
    echo ""
    read -p "  RAM threshold % [$ALERT_RAM_THRESHOLD]: " NEW_RAM
    read -p "  Disk threshold % [$ALERT_DISK_THRESHOLD]: " NEW_DISK
    read -p "  CPU threshold % [$ALERT_CPU_THRESHOLD]: " NEW_CPU

    # Validate: must be numbers between 1-99
    for val in "$NEW_RAM" "$NEW_DISK" "$NEW_CPU"; do
        if [ -n "$val" ] && { ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 99 ]; }; then
            echo -e "  ${RED}Invalid value: $val (must be 1-99)${NC}"
            pause; return
        fi
    done

    cat > "$ALERT_CONFIG" << ALERTEOF
ALERT_RAM_THRESHOLD=${NEW_RAM:-$ALERT_RAM_THRESHOLD}
ALERT_DISK_THRESHOLD=${NEW_DISK:-$ALERT_DISK_THRESHOLD}
ALERT_CPU_THRESHOLD=${NEW_CPU:-$ALERT_CPU_THRESHOLD}
ALERT_SWAP_THRESHOLD=${ALERT_SWAP_THRESHOLD}
ALERTEOF
    chmod 600 "$ALERT_CONFIG"
    echo -e "  ${GREEN}✓ Thresholds updated${NC}"

    # Setup cron
    if ! crontab -l 2>/dev/null | grep -q "resource_check"; then
        read -p "  Enable cron alert every 5 min? (Y/n): " ENABLE_CRON
        if [[ "$ENABLE_CRON" != "n" ]]; then
            (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/vps-admin.sh resource-check >> /var/log/resource_alert.log 2>&1") | crontab -
            echo -e "  ${GREEN}✓ Cron alert enabled${NC}"
        fi
    fi
    pause
}

# ── Menu ──
menu_resource_alert() {
    header
    echo -e "${WHITE}${BOLD}  RESOURCE ALERTS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} View current resources"
    echo -e "  ${CYAN}2.${NC} Test alert now"
    echo -e "  ${CYAN}3.${NC} Configure thresholds"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " RA_CHOICE

    case $RA_CHOICE in
        1) resource_status ;;
        2) resource_check; echo ""; echo -e "  ${GREEN}✓ Alert check done${NC}"; pause ;;
        3) resource_config ;;
    esac
}
