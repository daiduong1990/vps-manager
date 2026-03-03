#!/bin/bash
# ================================================================
#  Module: Domain Health Dashboard
#  All-in-one view: HTTP, SSL, TTFB, DB size, disk per site
# ================================================================

domain_health_dashboard() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  📊  DOMAIN HEALTH DASHBOARD                                        ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Collect domains
    local domains=()
    if [ -n "$DOMAINS" ]; then
        IFS=',' read -ra domains <<< "$DOMAINS"
    else
        for conf in /etc/nginx/conf.d/*.conf; do
            [ -f "$conf" ] || continue
            local sn=$(grep -m1 'server_name' "$conf" 2>/dev/null | sed 's/server_name//;s/;//;s/www\.//g' | xargs | awk '{print $1}')
            [ -n "$sn" ] && [[ "$sn" != "_" ]] && domains+=("$sn")
        done
    fi

    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "  ${RED}No domains found${NC}"
        pause; return
    fi

    # Table header
    printf "  ${WHITE}%-25s %-6s %-14s %-8s %-10s %-10s${NC}\n" "Domain" "HTTP" "SSL Expiry" "TTFB" "DB Size" "Disk"
    echo -e "  ${GREEN}─────────────────────────────────────────────────────────────────────${NC}"

    for d in "${domains[@]}"; do
        d=$(echo "$d" | xargs)
        [ -z "$d" ] && continue

        # HTTP status
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://$d" 2>/dev/null)
        local http_color="$RED"
        [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ] && http_color="$GREEN"

        # SSL expiry
        local ssl_expiry="N/A"
        local ssl_color="$YELLOW"
        local ssl_date=$(echo | openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        if [ -n "$ssl_date" ]; then
            local exp_epoch=$(date -d "$ssl_date" +%s 2>/dev/null)
            local now_epoch=$(date +%s)
            if [ -n "$exp_epoch" ]; then
                local days_left=$(( (exp_epoch - now_epoch) / 86400 ))
                ssl_expiry="${days_left}d"
                ssl_color="$GREEN"
                [ "$days_left" -le 30 ] && ssl_color="$YELLOW"
                [ "$days_left" -le 14 ] && ssl_color="$RED"
            fi
        fi

        # TTFB
        local ttfb=$(curl -s -o /dev/null -w "%{time_starttransfer}" --connect-timeout 5 "https://$d" 2>/dev/null)
        local ttfb_color="$GREEN"
        if [ -n "$ttfb" ]; then
            local ttfb_ms=$(awk "BEGIN {printf \"%d\", $ttfb * 1000}" 2>/dev/null)
            ttfb="${ttfb_ms}ms"
            [ "${ttfb_ms:-0}" -ge 500 ] && ttfb_color="$YELLOW"
            [ "${ttfb_ms:-0}" -ge 1000 ] && ttfb_color="$RED"
        else
            ttfb="N/A"
            ttfb_color="$RED"
        fi

        # DB size
        local db_size="N/A"
        local db_name=""
        for site_dir in "/home/$d/public_html" "/var/www/$d"; do
            if [ -f "$site_dir/wp-config.php" ]; then
                db_name=$(grep "DB_NAME" "$site_dir/wp-config.php" 2>/dev/null | grep -oP "'[^']+'" | tail -1 | tr -d "'")
                break
            fi
        done
        if [ -n "$db_name" ]; then
            if type _split_mysql &>/dev/null; then
                db_size=$(_split_mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) FROM information_schema.TABLES WHERE table_schema='${db_name}'" 2>/dev/null)
            elif type _mysql &>/dev/null; then
                db_size=$(_mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) FROM information_schema.TABLES WHERE table_schema='${db_name}'" 2>/dev/null)
            fi
            [ -n "$db_size" ] && db_size="${db_size}MB" || db_size="N/A"
        fi

        # Disk usage per site
        local disk_usage="N/A"
        for site_dir in "/home/$d/public_html" "/home/$d" "/var/www/$d"; do
            if [ -d "$site_dir" ]; then
                disk_usage=$(du -sh "$site_dir" 2>/dev/null | awk '{print $1}')
                break
            fi
        done

        printf "  %-25s ${http_color}%-6s${NC} ${ssl_color}%-14s${NC} ${ttfb_color}%-8s${NC} %-10s %-10s\n" \
            "$d" "$http_code" "$ssl_expiry" "$ttfb" "$db_size" "$disk_usage"
    done

    echo ""

    # System overview
    echo -e "  ${WHITE}${BOLD}System:${NC}"
    echo -e "    RAM:  $(free -h | awk '/Mem:/ {printf "%s/%s (%d%%)", $3, $2, $3/$2*100}')"
    echo -e "    Disk: $(df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')"
    echo -e "    Load: $(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
    echo ""
    pause
}

# ── Menu (direct call — no submenu needed) ──
menu_domain_health() {
    domain_health_dashboard
}
