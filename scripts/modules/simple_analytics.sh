#!/bin/bash
# ================================================================
#  Module: Simple Analytics — Parse nginx access logs
#  Top pages, IPs, bandwidth, bots vs humans — no external tools
# ================================================================

NGINX_LOG="/var/log/nginx/access.log"

# ── Parse time range ──
_analytics_filter_log() {
    local range="${1:-today}"
    local log_file="${2:-$NGINX_LOG}"

    [ ! -f "$log_file" ] && return

    case "$range" in
        today)
            local today=$(date '+%d/%b/%Y')
            grep "$today" "$log_file" 2>/dev/null
            ;;
        yesterday)
            local yesterday=$(date -d 'yesterday' '+%d/%b/%Y' 2>/dev/null || date -v-1d '+%d/%b/%Y' 2>/dev/null)
            [ -n "$yesterday" ] && grep "$yesterday" "$log_file" 2>/dev/null
            ;;
        7days)
            # Last 7 days — just use last ~50000 lines as approximation
            tail -50000 "$log_file" 2>/dev/null
            ;;
        all)
            cat "$log_file" 2>/dev/null
            ;;
    esac
}

# ── Top pages ──
analytics_top_pages() {
    local range="$1"
    echo ""
    echo -e "  ${WHITE}${BOLD}Top 20 Pages ($range):${NC}"
    echo -e "  ${GREEN}───────────────────────────────────────────${NC}"

    _analytics_filter_log "$range" | \
        awk '{print $7}' | \
        grep -vE '\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|map)(\?|$)' | \
        sort | uniq -c | sort -rn | head -20 | \
        awk '{printf "    %6d  %s\n", $1, $2}'
}

# ── Top IPs ──
analytics_top_ips() {
    local range="$1"
    echo ""
    echo -e "  ${WHITE}${BOLD}Top 20 IPs ($range):${NC}"
    echo -e "  ${GREEN}───────────────────────────────────────────${NC}"

    _analytics_filter_log "$range" | \
        awk '{print $1}' | \
        sort | uniq -c | sort -rn | head -20 | \
        awk '{printf "    %6d  %s\n", $1, $2}'
}

# ── Bandwidth ──
analytics_bandwidth() {
    local range="$1"
    echo ""
    echo -e "  ${WHITE}${BOLD}Bandwidth ($range):${NC}"
    echo -e "  ${GREEN}───────────────────────────────────────────${NC}"

    local total_bytes=$(_analytics_filter_log "$range" | \
        awk '{s+=$10} END {print s+0}')

    if [ "${total_bytes:-0}" -ge 1073741824 ]; then
        local gb=$(awk "BEGIN {printf \"%.2f\", $total_bytes/1073741824}")
        echo -e "    Total: ${CYAN}${gb} GB${NC}"
    elif [ "${total_bytes:-0}" -ge 1048576 ]; then
        local mb=$(awk "BEGIN {printf \"%.1f\", $total_bytes/1048576}")
        echo -e "    Total: ${CYAN}${mb} MB${NC}"
    else
        echo -e "    Total: ${CYAN}${total_bytes:-0} bytes${NC}"
    fi

    # Bandwidth by day
    echo ""
    echo -e "  ${WHITE}Per day:${NC}"
    _analytics_filter_log "$range" | \
        awk '{
            split($4, a, "[/:]");
            day=a[1]"/"a[2]"/"a[3];
            gsub(/^\[/, "", day);
            bytes[day]+=$10;
        } END {
            for (d in bytes) {
                mb = bytes[d] / 1048576;
                printf "    %s  %.1f MB\n", d, mb;
            }
        }' | sort -t/ -k3,3 -k2,2M -k1,1n | tail -7
}

# ── Bot vs Human traffic ──
analytics_bot_human() {
    local range="$1"
    echo ""
    echo -e "  ${WHITE}${BOLD}Bot vs Human Traffic ($range):${NC}"
    echo -e "  ${GREEN}───────────────────────────────────────────${NC}"

    local total=$(_analytics_filter_log "$range" | wc -l)
    local bots=$(_analytics_filter_log "$range" | \
        grep -ciE '(bot|crawl|spider|slurp|Baiduspider|Yandex|Sogou|DotBot|AhrefsBot|MJ12bot|SemrushBot|serpstat|DataForSeoBot)' 2>/dev/null)

    local humans=$((total - ${bots:-0}))
    local bot_pct=0
    [ "$total" -gt 0 ] && bot_pct=$((${bots:-0} * 100 / total))

    echo -e "    Total requests: ${WHITE}$total${NC}"
    echo -e "    Bots:   ${YELLOW}${bots:-0}${NC} (${bot_pct}%)"
    echo -e "    Humans: ${GREEN}$humans${NC} ($((100-bot_pct))%)"
    echo ""

    # Top bots
    echo -e "  ${WHITE}Top bots:${NC}"
    _analytics_filter_log "$range" | \
        grep -iE '(bot|crawl|spider)' | \
        grep -oiE '(Googlebot|bingbot|Baiduspider|YandexBot|DotBot|AhrefsBot|SemrushBot|MJ12bot|facebookexternalhit|Twitterbot|LinkedInBot|PetalBot|DataForSeoBot|[a-zA-Z]*[Bb]ot)' | \
        sort | uniq -c | sort -rn | head -10 | \
        awk '{printf "    %6d  %s\n", $1, $2}'
}

# ── 404 errors ──
analytics_404() {
    local range="$1"
    echo ""
    echo -e "  ${WHITE}${BOLD}404 Not Found ($range):${NC}"
    echo -e "  ${GREEN}───────────────────────────────────────────${NC}"

    _analytics_filter_log "$range" | \
        awk '$9 == 404 {print $7}' | \
        sort | uniq -c | sort -rn | head -20 | \
        awk '{printf "    %6d  %s\n", $1, $2}'

    local total_404=$(_analytics_filter_log "$range" | awk '$9 == 404' | wc -l)
    echo ""
    echo -e "    Total 404s: ${RED}$total_404${NC}"
}

# ── HTTP status distribution ──
analytics_status_codes() {
    local range="$1"
    echo ""
    echo -e "  ${WHITE}${BOLD}HTTP Status Codes ($range):${NC}"
    echo -e "  ${GREEN}───────────────────────────────────────────${NC}"

    _analytics_filter_log "$range" | \
        awk '{print $9}' | sort | uniq -c | sort -rn | head -10 | \
        while read count code; do
            local color="$WHITE"
            [[ "$code" =~ ^2 ]] && color="$GREEN"
            [[ "$code" =~ ^3 ]] && color="$CYAN"
            [[ "$code" =~ ^4 ]] && color="$YELLOW"
            [[ "$code" =~ ^5 ]] && color="$RED"
            printf "    ${color}%s${NC}  %6d\n" "$code" "$count"
        done
}

# ── Full report ──
analytics_full_report() {
    local range="$1"
    analytics_top_pages "$range"
    analytics_top_ips "$range"
    analytics_bandwidth "$range"
    analytics_bot_human "$range"
    analytics_404 "$range"
    analytics_status_codes "$range"
}

# ── Menu ──
menu_simple_analytics() {
    header
    echo -e "${WHITE}${BOLD}  SIMPLE ANALYTICS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""

    # Choose time range
    echo -e "  ${WHITE}Time range:${NC}"
    echo -e "    ${CYAN}1)${NC} Today"
    echo -e "    ${CYAN}2)${NC} Yesterday"
    echo -e "    ${CYAN}3)${NC} Last 7 days"
    echo -e "    ${CYAN}4)${NC} All time"
    echo ""
    read -p "  Select range [1-4]: " RANGE_PICK

    local range=""
    case $RANGE_PICK in
        1) range="today" ;;
        2) range="yesterday" ;;
        3) range="7days" ;;
        4) range="all" ;;
        *) echo -e "  ${RED}Invalid${NC}"; pause; return ;;
    esac

    echo ""
    echo -e "  ${WHITE}Report type:${NC}"
    echo -e "    ${CYAN}1)${NC} Full report"
    echo -e "    ${CYAN}2)${NC} Top pages only"
    echo -e "    ${CYAN}3)${NC} Top IPs only"
    echo -e "    ${CYAN}4)${NC} Bandwidth"
    echo -e "    ${CYAN}5)${NC} Bot vs Human"
    echo -e "    ${CYAN}6)${NC} 404 errors"
    echo -e "    ${CYAN}7)${NC} Status codes"
    echo -e "    ${RED}0)${NC} Back"
    echo ""
    read -p "  Select: " RPT_PICK

    case $RPT_PICK in
        1) analytics_full_report "$range" ;;
        2) analytics_top_pages "$range" ;;
        3) analytics_top_ips "$range" ;;
        4) analytics_bandwidth "$range" ;;
        5) analytics_bot_human "$range" ;;
        6) analytics_404 "$range" ;;
        7) analytics_status_codes "$range" ;;
    esac
    pause
}
