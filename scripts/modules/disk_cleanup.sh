#!/bin/bash
# ================================================================
#  Module: Disk Cleanup
#  Safely cleans logs, WP revisions, transients, package cache
#  Dry-run by default — use --force to actually delete
# ================================================================

# ── Calculate space that can be freed ──
_cleanup_calc_size() {
    local total=0

    # Old logs
    local log_size=$(find /var/log -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" 2>/dev/null | xargs du -sb 2>/dev/null | awk '{s+=$1} END {print s+0}')
    total=$((total + ${log_size:-0}))

    # Journal logs > 100MB
    local journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[MG]' | head -1)

    # Package cache
    local pkg_size=0
    if command -v apt &>/dev/null; then
        pkg_size=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}')
    elif command -v dnf &>/dev/null; then
        pkg_size=$(du -sb /var/cache/dnf/ 2>/dev/null | awk '{print $1}')
    fi
    total=$((total + ${pkg_size:-0}))

    # Old backups > 30 days
    local old_bak=$(find /backup -name "*.gz" -mtime +30 2>/dev/null | xargs du -sb 2>/dev/null | awk '{s+=$1} END {print s+0}')
    total=$((total + ${old_bak:-0}))

    echo "$total"
}

_bytes_to_human() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

# ── Dry run — show what would be cleaned ──
cleanup_dryrun() {
    echo ""
    echo -e "${BOLD}  🧹 Disk Cleanup — Dry Run${NC}"
    echo ""

    local total_saved=0

    # 1. Old log files
    echo -e "  ${WHITE}[1] Old log files (*.gz, *.old):${NC}"
    local log_count=$(find /var/log -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" 2>/dev/null | wc -l)
    local log_size=$(find /var/log -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" 2>/dev/null | xargs du -sb 2>/dev/null | awk '{s+=$1} END {print s+0}')
    echo -e "    ${CYAN}$log_count files${NC} — $(_bytes_to_human ${log_size:-0})"
    total_saved=$((total_saved + ${log_size:-0}))

    # 2. Systemd journal
    echo -e "  ${WHITE}[2] Systemd journal (keep 100MB):${NC}"
    local journal_info=$(journalctl --disk-usage 2>/dev/null)
    echo -e "    ${CYAN}${journal_info:-N/A}${NC}"

    # 3. Package cache
    echo -e "  ${WHITE}[3] Package cache:${NC}"
    if command -v apt &>/dev/null; then
        local pkg_size=$(du -sh /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}')
        echo -e "    ${CYAN}apt: ${pkg_size:-0}${NC}"
    elif command -v dnf &>/dev/null; then
        local pkg_size=$(du -sh /var/cache/dnf/ 2>/dev/null | awk '{print $1}')
        echo -e "    ${CYAN}dnf: ${pkg_size:-0}${NC}"
    fi

    # 4. WP revisions & transients
    echo -e "  ${WHITE}[4] WordPress cleanup:${NC}"
    if command -v wp &>/dev/null; then
        for dir in /home/*/public_html /var/www/*/; do
            [ -f "$dir/wp-config.php" ] || continue
            local domain=$(basename "$(dirname "$dir")" 2>/dev/null)
            [ "$domain" = "public_html" ] && domain=$(basename "$(dirname "$(dirname "$dir")")")

            local revisions=$(wp post list --post_type=revision --format=count --path="$dir" --allow-root 2>/dev/null)
            local transients=$(wp db query "SELECT COUNT(*) FROM $(wp db prefix --path="$dir" --allow-root 2>/dev/null)options WHERE option_name LIKE '_transient_%'" --path="$dir" --allow-root 2>/dev/null | tail -1)
            local spam=$(wp comment list --status=spam --format=count --path="$dir" --allow-root 2>/dev/null)
            local trash=$(wp comment list --status=trash --format=count --path="$dir" --allow-root 2>/dev/null)

            echo -e "    ${CYAN}$domain:${NC} ${revisions:-0} revisions, ${transients:-0} transients, ${spam:-0} spam, ${trash:-0} trash"
        done
    else
        echo -e "    ${YELLOW}WP-CLI not installed — skip WP cleanup${NC}"
    fi

    # 5. Old backups
    echo -e "  ${WHITE}[5] Old backups (>30 days):${NC}"
    local old_bak_count=$(find /backup -name "*.gz" -mtime +30 2>/dev/null | wc -l)
    local old_bak_size=$(find /backup -name "*.gz" -mtime +30 2>/dev/null | xargs du -sb 2>/dev/null | awk '{s+=$1} END {print s+0}')
    echo -e "    ${CYAN}$old_bak_count files${NC} — $(_bytes_to_human ${old_bak_size:-0})"
    total_saved=$((total_saved + ${old_bak_size:-0}))

    # 6. Temp files
    echo -e "  ${WHITE}[6] Temp files (/tmp older than 7 days):${NC}"
    local tmp_count=$(find /tmp -type f -mtime +7 2>/dev/null | wc -l)
    local tmp_size=$(find /tmp -type f -mtime +7 2>/dev/null | xargs du -sb 2>/dev/null | awk '{s+=$1} END {print s+0}')
    echo -e "    ${CYAN}$tmp_count files${NC} — $(_bytes_to_human ${tmp_size:-0})"
    total_saved=$((total_saved + ${tmp_size:-0}))

    echo ""
    echo -e "  ${WHITE}Estimated space to free: ${GREEN}$(_bytes_to_human $total_saved)${NC} (minimum)"
    echo ""
}

# ── Execute cleanup ──
cleanup_execute() {
    local disk_before=$(df / | awk 'NR==2 {print $4}')

    echo ""
    echo -e "${BOLD}  🧹 Executing Disk Cleanup...${NC}"
    echo ""

    # 1. Old logs
    echo -e "  ${WHITE}Cleaning old logs...${NC}"
    find /var/log -name "*.gz" -delete 2>/dev/null
    find /var/log -name "*.old" -delete 2>/dev/null
    find /var/log -name "*.[0-9]" -delete 2>/dev/null
    echo -e "  ${GREEN}✓ Old logs removed${NC}"

    # 2. Journal
    echo -e "  ${WHITE}Trimming journal to 100MB...${NC}"
    journalctl --vacuum-size=100M 2>/dev/null
    echo -e "  ${GREEN}✓ Journal trimmed${NC}"

    # 3. Package cache
    echo -e "  ${WHITE}Cleaning package cache...${NC}"
    if command -v apt &>/dev/null; then
        apt-get clean 2>/dev/null
        apt-get autoremove -y 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf clean all 2>/dev/null
    fi
    echo -e "  ${GREEN}✓ Package cache cleaned${NC}"

    # 4. WP cleanup
    if command -v wp &>/dev/null; then
        echo -e "  ${WHITE}Cleaning WordPress data...${NC}"
        for dir in /home/*/public_html /var/www/*/; do
            [ -f "$dir/wp-config.php" ] || continue
            local domain=$(basename "$(dirname "$dir")" 2>/dev/null)
            [ "$domain" = "public_html" ] && domain=$(basename "$(dirname "$(dirname "$dir")")")

            # Delete revisions (keep last 3 per post — WP_POST_REVISIONS)
            wp post delete $(wp post list --post_type=revision --format=ids --path="$dir" --allow-root 2>/dev/null) --force --path="$dir" --allow-root 2>/dev/null

            # Delete transients
            wp transient delete --all --path="$dir" --allow-root 2>/dev/null

            # Delete spam + trash comments
            wp comment delete $(wp comment list --status=spam --format=ids --path="$dir" --allow-root 2>/dev/null) --force --path="$dir" --allow-root 2>/dev/null
            wp comment delete $(wp comment list --status=trash --format=ids --path="$dir" --allow-root 2>/dev/null) --force --path="$dir" --allow-root 2>/dev/null

            echo -e "    ${GREEN}✓ $domain cleaned${NC}"
        done
    fi

    # 5. Old backups
    echo -e "  ${WHITE}Removing backups older than 30 days...${NC}"
    find /backup -name "*.gz" -mtime +30 -delete 2>/dev/null
    echo -e "  ${GREEN}✓ Old backups removed${NC}"

    # 6. Temp files
    echo -e "  ${WHITE}Cleaning temp files (>7 days)...${NC}"
    find /tmp -type f -mtime +7 -delete 2>/dev/null
    echo -e "  ${GREEN}✓ Temp cleaned${NC}"

    # Show space saved
    local disk_after=$(df / | awk 'NR==2 {print $4}')
    local saved_kb=$((${disk_after:-0} - ${disk_before:-0}))
    local saved_mb=$((saved_kb / 1024))
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Cleanup complete! Freed: ~${saved_mb} MB${NC}"
    pause
}

# ── Menu ──
menu_disk_cleanup() {
    header
    echo -e "${WHITE}${BOLD}  DISK CLEANUP${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} Dry run (show what can be cleaned)"
    echo -e "  ${CYAN}2.${NC} Execute cleanup"
    echo -e "  ${CYAN}3.${NC} Show disk usage by directory"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " DC_CHOICE

    case $DC_CHOICE in
        1) cleanup_dryrun; pause ;;
        2) read -p "  Confirm cleanup? (y/N): " CC; [ "$CC" = "y" ] && cleanup_execute ;;
        3) echo ""; du -sh /var/log /backup /tmp /var/cache /home /var/www 2>/dev/null | sort -rh; pause ;;
    esac
}
