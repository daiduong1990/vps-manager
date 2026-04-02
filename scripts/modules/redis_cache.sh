#!/bin/bash
# ================================================================
#  Module: redis_cache.sh
#  Redis Object Cache Manager for WordPress + Server Cache
#  Usage: sourced by vps-admin.sh
# ================================================================

menu_redis_cache() {
    while true; do
        header
        echo -e "${WHITE}${BOLD}  🗃️  REDIS CACHE MANAGER${NC}"
        echo -e "${GREEN}  ─────────────────────────────────${NC}"

        # Live Redis status
        local redis_status hit_rate hits misses connected_clients mem_used
        if command -v redis-cli &>/dev/null && redis-cli ping 2>/dev/null | grep -q PONG; then
            hits=$(redis-cli info stats 2>/dev/null | grep keyspace_hits | cut -d: -f2 | tr -d '\r')
            misses=$(redis-cli info stats 2>/dev/null | grep keyspace_misses | cut -d: -f2 | tr -d '\r')
            connected_clients=$(redis-cli info clients 2>/dev/null | grep connected_clients | cut -d: -f2 | tr -d '\r')
            mem_used=$(redis-cli info memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '\r ')
            hits=${hits:-0}; misses=${misses:-0}
            if [[ $((hits + misses)) -gt 0 ]]; then
                hit_rate=$((hits * 100 / (hits + misses)))
            else
                hit_rate=0
            fi
            if [[ $hit_rate -ge 80 ]]; then
                rate_color="${GREEN}"
            elif [[ $hit_rate -ge 50 ]]; then
                rate_color="${YELLOW}"
            else
                rate_color="${RED}"
            fi
            echo -e "  Redis: ${GREEN}●  RUNNING${NC}  |  Clients: ${connected_clients}  |  Mem: ${mem_used}"
            echo -e "  Cache: Hits=$hits  Misses=$misses  ${rate_color}Hit Rate: ${hit_rate}%${NC}"
        else
            echo -e "  Redis: ${RED}○  STOPPED or NOT INSTALLED${NC}"
        fi

        echo -e "${GREEN}  ─────────────────────────────────${NC}"
        echo -e "  ${CYAN}1.${NC} 📊 Redis Stats (full info)"
        echo -e "  ${CYAN}2.${NC} 🔑 Show all Redis keys (by DB)"
        echo -e "  ${CYAN}3.${NC} 🗑️  Flush Redis cache (full)"
        echo -e "  ${CYAN}4.${NC} 🔌 Install WordPress Redis Object Cache plugin (WP-CLI)"
        echo -e "  ${CYAN}5.${NC} ✅ Verify WordPress Redis is connected (all sites)"
        echo -e "  ${CYAN}6.${NC} ⚙️  Tune Redis config (maxmemory + LRU eviction)"
        echo -e "  ${CYAN}7.${NC} 🔄 Restart Redis"
        echo -e "  ${RED}0.${NC} Back"
        echo ""
        read -p "  Select: " REDIS_CHOICE

        case $REDIS_CHOICE in
            1) do_redis_stats ;;
            2) do_redis_keys ;;
            3) do_redis_flush ;;
            4) do_install_wp_redis ;;
            5) do_verify_wp_redis ;;
            6) do_tune_redis ;;
            7) do_restart_redis ;;
            0) break ;;
        esac
    done
}

do_redis_stats() {
    echo ""
    echo -e "  ${WHITE}${BOLD}Redis Full Stats:${NC}"
    redis-cli info all 2>/dev/null | grep -E 'redis_version|used_memory_human|maxmemory_human|connected_clients|keyspace_hits|keyspace_misses|evicted_keys|expired_keys|uptime_in_days|role' | \
        while IFS=: read key val; do
            printf "  %-30s %s\n" "$key" "$(echo $val | tr -d '\r')"
        done
    echo ""
    echo -e "  ${WHITE}${BOLD}Keyspace:${NC}"
    redis-cli info keyspace 2>/dev/null | grep -v '^#' | grep -v '^$'
    pause
}

do_redis_keys() {
    echo ""
    local num_keys
    num_keys=$(redis-cli dbsize 2>/dev/null | tr -d '\r')
    echo -e "  Total keys in Redis: ${CYAN}${num_keys:-0}${NC}"
    if [[ "${num_keys:-0}" -gt 500 ]]; then
        echo -e "  ${YELLOW}(Too many keys, showing first 50 patterns)${NC}"
        redis-cli --scan --count 50 2>/dev/null | head -50 | sed 's/^/  /'
    elif [[ "${num_keys:-0}" -gt 0 ]]; then
        redis-cli keys '*' 2>/dev/null | head -100 | sed 's/^/  /'
    else
        echo -e "  ${YELLOW}Cache is empty. This means WordPress redis plugin may not be connected.${NC}"
    fi
    pause
}

do_redis_flush() {
    echo ""
    local num_keys
    num_keys=$(redis-cli dbsize 2>/dev/null | tr -d '\r')
    echo -e "  ${YELLOW}⚠ About to flush ALL ${num_keys:-0} Redis keys${NC}"
    read -p "  Confirm flush? (y/N): " C
    [ "$C" != "y" ] && return
    redis-cli FLUSHALL 2>/dev/null && echo -e "  ${GREEN}✓ Redis cache flushed${NC}" || echo -e "  ${RED}✗ Flush failed${NC}"
    pause
}

do_install_wp_redis() {
    echo ""
    if ! command -v wp &>/dev/null; then
        echo -e "  ${RED}✗ WP-CLI not found. Run: vps-admin → 12 → Install components${NC}"
        pause; return
    fi

    _load_domains
    if [ ${#_domain_list[@]} -eq 0 ]; then
        echo -e "  ${RED}No WordPress sites found${NC}"
        pause; return
    fi

    echo -e "  ${WHITE}Found ${#_domain_list[@]} WordPress site(s):${NC}"
    local i=1
    for d in "${_domain_list[@]}"; do
        echo -e "  $i) $d"
        ((i++))
    done
    echo -e "  a) Install on ALL sites"
    read -p "  Select [1-${#_domain_list[@]}|a]: " PICK

    local sites_to_process=()
    if [[ "$PICK" == "a" ]]; then
        sites_to_process=("${_domain_list[@]}")
    elif [[ "$PICK" =~ ^[0-9]+$ ]] && [ "$PICK" -ge 1 ] && [ "$PICK" -le ${#_domain_list[@]} ]; then
        sites_to_process=("${_domain_list[$((PICK-1))]}")
    else
        echo -e "  ${RED}Invalid selection${NC}"; pause; return
    fi

    for domain in "${sites_to_process[@]}"; do
        local wp_path=""
        for p in "/home/$domain/public_html" "/var/www/$domain" "/home/$domain"; do
            [ -f "$p/wp-config.php" ] && wp_path="$p" && break
        done
        if [ -z "$wp_path" ]; then
            echo -e "  ${YELLOW}⚠ $domain: wp-config.php not found, skipping${NC}"
            continue
        fi

        echo -e "  ${CYAN}Processing $domain ($wp_path)...${NC}"

        # Install plugin
        if wp plugin is-installed redis-cache --path="$wp_path" --allow-root 2>/dev/null; then
            echo -e "  ${GREEN}✓ redis-cache plugin already installed${NC}"
        else
            wp plugin install redis-cache --activate --path="$wp_path" --allow-root 2>/dev/null && \
                echo -e "  ${GREEN}✓ Redis Object Cache plugin installed + activated${NC}" || \
                echo -e "  ${RED}✗ Plugin install failed for $domain${NC}"
        fi

        # Add Redis config to wp-config.php if missing
        if ! grep -q 'WP_REDIS_HOST' "$wp_path/wp-config.php" 2>/dev/null; then
            sed -i "/\/\* That's all, stop editing/i define('WP_REDIS_HOST', '127.0.0.1');\ndefine('WP_REDIS_PORT', 6379);\ndefine('WP_REDIS_DATABASE', 0);\ndefine('WP_CACHE', true);\n" \
                "$wp_path/wp-config.php" 2>/dev/null
            echo -e "  ${GREEN}✓ Redis constants added to wp-config.php${NC}"
        fi

        # Enable the plugin's object cache drop-in
        wp redis enable --path="$wp_path" --allow-root 2>/dev/null && \
            echo -e "  ${GREEN}✓ Redis object cache drop-in enabled${NC}" || \
            echo -e "  ${YELLOW}⚠ wp redis enable failed — may need manual activation${NC}"
    done
    pause
}

do_verify_wp_redis() {
    echo ""
    echo -e "  ${WHITE}${BOLD}Checking Redis connection for all WordPress sites:${NC}"
    echo ""
    _load_domains
    for domain in "${_domain_list[@]}"; do
        local wp_path=""
        for p in "/home/$domain/public_html" "/var/www/$domain" "/home/$domain"; do
            [ -f "$p/wp-config.php" ] && wp_path="$p" && break
        done
        [ -z "$wp_path" ] && continue

        local has_redis has_dropin
        has_redis=$(grep -c 'WP_REDIS_HOST' "$wp_path/wp-config.php" 2>/dev/null || echo 0)
        has_dropin=$([ -f "$wp_path/wp-content/object-cache.php" ] && echo 1 || echo 0)

        if [[ "$has_redis" -gt 0 ]] && [[ "$has_dropin" -eq 1 ]]; then
            echo -e "  ${GREEN}✓${NC} $domain — Redis configured + drop-in present"
        elif [[ "$has_redis" -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠${NC} $domain — WP_REDIS_HOST set but no object-cache.php drop-in (wp plugin install redis-cache)"
        else
            echo -e "  ${RED}✗${NC} $domain — Redis NOT configured"
        fi
    done

    # Also check actual Redis DB size
    echo ""
    local db_size
    db_size=$(redis-cli dbsize 2>/dev/null | tr -d '\r')
    if [[ "${db_size:-0}" -gt 0 ]]; then
        echo -e "  ${GREEN}Redis has $db_size keys — cache is actively being used!${NC}"
    else
        echo -e "  ${YELLOW}Redis has 0 keys — enable Redis on a site to populate cache${NC}"
    fi
    pause
}

do_tune_redis() {
    echo ""
    read -p "  Max memory for Redis [256mb]: " MAXMEM
    MAXMEM="${MAXMEM:-256mb}"
    # Validate: only allow digits + mb/gb
    [[ ! "$MAXMEM" =~ ^[0-9]+(mb|gb|M|G)$ ]] && echo -e "  ${RED}Invalid format. Use e.g. 256mb${NC}" && pause && return

    local redis_conf
    redis_conf=$(find /etc/redis* -name "*.conf" 2>/dev/null | head -1)
    if [ -z "$redis_conf" ]; then
        echo -e "  ${RED}✗ Redis config not found${NC}"; pause; return
    fi

    # Set maxmemory + LRU policy
    sed -i "/^maxmemory /d; /^maxmemory-policy /d" "$redis_conf"
    echo "maxmemory $MAXMEM" >> "$redis_conf"
    echo "maxmemory-policy allkeys-lru" >> "$redis_conf"

    systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null
    echo -e "  ${GREEN}✓ Redis maxmemory=$MAXMEM, policy=allkeys-lru${NC}"
    echo -e "  ${CYAN}LRU eviction: Redis auto-removes oldest keys when full${NC}"
    pause
}

do_restart_redis() {
    echo ""
    systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null
    sleep 1
    if systemctl is-active redis 2>/dev/null || systemctl is-active redis-server 2>/dev/null; then
        echo -e "  ${GREEN}✓ Redis restarted${NC}"
    else
        echo -e "  ${RED}✗ Redis failed to start. Check: journalctl -xe${NC}"
    fi
    pause
}
