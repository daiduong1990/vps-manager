#!/bin/bash
# ================================================================
#  Module: WordPress Auto-Update with Rollback
#  Updates WP core, plugins, themes — with full backup before update
# ================================================================

WP_UPDATE_LOG="/var/log/wp-update.log"

_wp_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$WP_UPDATE_LOG"; }

# ── Get all WP sites ──
_get_wp_sites() {
    for dir in /home/*/public_html /var/www/*/; do
        [ -f "$dir/wp-config.php" ] && echo "$dir"
    done
}

# ── Update single site ──
_update_wp_site() {
    local site_dir="$1"
    local domain=$(basename "$(dirname "$site_dir")" 2>/dev/null)
    [ "$domain" = "public_html" ] && domain=$(basename "$(dirname "$(dirname "$site_dir")")")

    echo -e "\n  ${WHITE}━━━ $domain ━━━${NC}"

    if ! command -v wp &>/dev/null; then
        echo -e "    ${RED}WP-CLI not installed${NC}"
        return 1
    fi

    # Check current versions
    local core_ver=$(wp core version --path="$site_dir" --allow-root 2>/dev/null)
    local core_update=$(wp core check-update --path="$site_dir" --allow-root --format=count 2>/dev/null)
    local plugin_updates=$(wp plugin list --path="$site_dir" --allow-root --update=available --format=count 2>/dev/null)
    local theme_updates=$(wp theme list --path="$site_dir" --allow-root --update=available --format=count 2>/dev/null)

    echo -e "    Core: ${CYAN}$core_ver${NC}"
    echo -e "    Plugin updates: ${YELLOW}${plugin_updates:-0}${NC}"
    echo -e "    Theme updates: ${YELLOW}${theme_updates:-0}${NC}"

    local total_updates=$(( ${core_update:-0} + ${plugin_updates:-0} + ${theme_updates:-0} ))
    if [ "$total_updates" -eq 0 ]; then
        echo -e "    ${GREEN}✓ Already up to date${NC}"
        return 0
    fi

    # Pre-update backup
    echo -e "    ${WHITE}Creating pre-update backup...${NC}"
    local bak_dir="/backup/pre-update/${domain}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$bak_dir"

    # DB backup
    local db_name=$(wp config get DB_NAME --path="$site_dir" --allow-root 2>/dev/null)
    if [ -n "$db_name" ]; then
        if type _split_mysqldump &>/dev/null; then
            _split_mysqldump "$db_name" 2>/dev/null | gzip > "$bak_dir/${db_name}.sql.gz"
        elif type _mysqldump &>/dev/null; then
            _mysqldump "$db_name" 2>/dev/null | gzip > "$bak_dir/${db_name}.sql.gz"
        fi
    fi

    # Files backup (plugins + themes only, not entire site)
    tar czf "$bak_dir/plugins.tar.gz" -C "$site_dir/wp-content" plugins/ 2>/dev/null
    tar czf "$bak_dir/themes.tar.gz" -C "$site_dir/wp-content" themes/ 2>/dev/null

    echo -e "    ${GREEN}✓ Backup saved: $bak_dir${NC}"
    _wp_log "PRE-UPDATE backup: $domain -> $bak_dir"

    # Update core
    if [ "${core_update:-0}" -gt 0 ]; then
        echo -e "    ${WHITE}Updating WordPress core...${NC}"
        if wp core update --path="$site_dir" --allow-root 2>/dev/null; then
            local new_ver=$(wp core version --path="$site_dir" --allow-root 2>/dev/null)
            echo -e "    ${GREEN}✓ Core: $core_ver → $new_ver${NC}"
            _wp_log "CORE updated: $domain $core_ver -> $new_ver"
        else
            echo -e "    ${RED}✗ Core update failed${NC}"
            _wp_log "CORE update FAILED: $domain"
        fi
        wp core update-db --path="$site_dir" --allow-root 2>/dev/null
    fi

    # Update plugins
    if [ "${plugin_updates:-0}" -gt 0 ]; then
        echo -e "    ${WHITE}Updating plugins...${NC}"
        wp plugin update --all --path="$site_dir" --allow-root 2>/dev/null
        echo -e "    ${GREEN}✓ $plugin_updates plugin(s) updated${NC}"
        _wp_log "PLUGINS updated: $domain ($plugin_updates)"
    fi

    # Update themes
    if [ "${theme_updates:-0}" -gt 0 ]; then
        echo -e "    ${WHITE}Updating themes...${NC}"
        wp theme update --all --path="$site_dir" --allow-root 2>/dev/null
        echo -e "    ${GREEN}✓ $theme_updates theme(s) updated${NC}"
        _wp_log "THEMES updated: $domain ($theme_updates)"
    fi

    # Verify site is working
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://$domain" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
        echo -e "    ${GREEN}✓ Site verified: HTTP $http_code${NC}"
    else
        echo -e "    ${RED}⚠ Site may be broken: HTTP $http_code${NC}"
        echo -e "    ${YELLOW}  Rollback: vps-admin → Quick Tools → WP Rollback${NC}"
        _wp_log "POST-UPDATE WARNING: $domain HTTP $http_code"
    fi

    # Telegram notification
    if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local msg="🔄 WP Updated: $domain | Core: ${core_ver}→${new_ver:-$core_ver} | Plugins: ${plugin_updates:-0} | HTTP: $http_code"
        curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=$msg" >/dev/null 2>&1
    fi
}

# ── Rollback from pre-update backup ──
wp_update_rollback() {
    echo ""
    echo -e "${BOLD}  🔄 WP Update Rollback${NC}"
    echo ""

    local bak_base="/backup/pre-update"
    if [ ! -d "$bak_base" ]; then
        echo -e "  ${RED}No pre-update backups found${NC}"
        pause; return
    fi

    local dirs=()
    while IFS= read -r d; do
        [ -d "$d" ] && dirs+=("$d")
    done < <(find "$bak_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -20)

    if [ ${#dirs[@]} -eq 0 ]; then
        echo -e "  ${RED}No backups found${NC}"
        pause; return
    fi

    echo -e "  ${YELLOW}Recent backups:${NC}"
    local i=1
    for d in "${dirs[@]}"; do
        local name=$(basename "$d")
        local size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        echo -e "    ${CYAN}$i)${NC} $name ($size)"
        ((i++))
    done

    echo ""
    read -p "  Select backup to restore [1-${#dirs[@]}]: " RB_PICK
    if ! [[ "$RB_PICK" =~ ^[0-9]+$ ]] || [ "$RB_PICK" -lt 1 ] || [ "$RB_PICK" -gt "${#dirs[@]}" ]; then
        echo -e "  ${RED}Invalid selection${NC}"
        pause; return
    fi

    local RESTORE_DIR="${dirs[$((RB_PICK-1))]}"
    local dir_name=$(basename "$RESTORE_DIR")
    # Extract domain from dirname pattern: domain_YYYYMMDD_HHMMSS
    local domain=$(echo "$dir_name" | sed 's/_[0-9]\{8\}_[0-9]\{6\}$//')

    # Validate domain format
    if [[ ! "$domain" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo -e "  ${RED}Invalid domain in backup name${NC}"
        pause; return
    fi

    local site_dir=""
    [ -d "/home/$domain/public_html" ] && site_dir="/home/$domain/public_html"
    [ -d "/var/www/$domain" ] && site_dir="/var/www/$domain"

    if [ -z "$site_dir" ]; then
        echo -e "  ${RED}Site directory not found for $domain${NC}"
        pause; return
    fi

    read -p "  Confirm rollback $domain? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && { pause; return; }

    # Restore plugins
    if [ -f "$RESTORE_DIR/plugins.tar.gz" ]; then
        echo -e "  ${WHITE}Restoring plugins...${NC}"
        rm -rf "$site_dir/wp-content/plugins"
        tar xzf "$RESTORE_DIR/plugins.tar.gz" -C "$site_dir/wp-content/" 2>/dev/null
        echo -e "  ${GREEN}✓ Plugins restored${NC}"
    fi

    # Restore themes
    if [ -f "$RESTORE_DIR/themes.tar.gz" ]; then
        echo -e "  ${WHITE}Restoring themes...${NC}"
        tar xzf "$RESTORE_DIR/themes.tar.gz" -C "$site_dir/wp-content/" 2>/dev/null
        echo -e "  ${GREEN}✓ Themes restored${NC}"
    fi

    # Restore DB
    local sql_files=$(find "$RESTORE_DIR" -name "*.sql.gz" 2>/dev/null)
    if [ -n "$sql_files" ]; then
        echo -e "  ${WHITE}Restoring database...${NC}"
        local db_name=$(wp config get DB_NAME --path="$site_dir" --allow-root 2>/dev/null)
        if [ -n "$db_name" ]; then
            for sqlgz in $sql_files; do
                gunzip -c "$sqlgz" | _split_mysql "$db_name" 2>/dev/null
            done
            echo -e "  ${GREEN}✓ Database restored${NC}"
        fi
    fi

    # Fix permissions
    chown -R nginx:nginx "$site_dir" 2>/dev/null || chown -R www-data:www-data "$site_dir"

    echo -e "  ${GREEN}✓ Rollback complete for $domain${NC}"
    _wp_log "ROLLBACK: $domain from $RESTORE_DIR"
    pause
}

# ── Update all sites ──
wp_update_all() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  ⬆️  WORDPRESS AUTO-UPDATE                 ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"

    local sites=()
    while IFS= read -r s; do
        [ -n "$s" ] && sites+=("$s")
    done < <(_get_wp_sites)

    if [ ${#sites[@]} -eq 0 ]; then
        echo -e "\n  ${RED}No WordPress sites found${NC}"
        pause; return
    fi

    echo -e "\n  ${WHITE}Found ${#sites[@]} WordPress site(s)${NC}"
    echo ""
    read -p "  Update all? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && { pause; return; }

    for site in "${sites[@]}"; do
        _update_wp_site "$site"
    done

    echo ""
    echo -e "  ${GREEN}${BOLD}All updates complete!${NC}"
    echo -e "  ${WHITE}Log: $WP_UPDATE_LOG${NC}"
    pause
}

# ── Menu ──
menu_wp_update() {
    header
    echo -e "${WHITE}${BOLD}  WORDPRESS AUTO-UPDATE${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} Update all sites (backup → update → verify)"
    echo -e "  ${CYAN}2.${NC} Rollback from pre-update backup"
    echo -e "  ${CYAN}3.${NC} View update log"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " WPU_CHOICE

    case $WPU_CHOICE in
        1) wp_update_all ;;
        2) wp_update_rollback ;;
        3) [ -f "$WP_UPDATE_LOG" ] && tail -50 "$WP_UPDATE_LOG" || echo "  No log yet"; pause ;;
    esac
}
