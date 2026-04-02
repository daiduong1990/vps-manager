#!/bin/bash
# ================================================================
#  VPS Admin Panel (HocVPS-style interactive menu)
#  Usage: vps-admin (or just type 'vps-admin' anywhere)
# ================================================================
set -o pipefail
readonly VER="2.5.1"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C

# Initialize config vars with defaults before sourcing (prevents set -u crash)
SERVER_IP="" DB_ROOT_PASS="" VPS_NAME="" DOMAINS="" VPS_LANG=""
source /root/.vps-config/setup.conf 2>/dev/null || true

# ── Language Loader (i18n) ──
load_lang() {
    local lang_dir="/usr/local/bin/vps-modules/lang"
    local lang="${VPS_LANG:-}"
    # Fallback chain: config → system locale → English
    if [ -z "$lang" ]; then
        lang=$(echo "${LANG:-en}" | cut -d_ -f1 | cut -d. -f1)
    fi
    [ -f "$lang_dir/${lang}.sh" ] || lang="en"
    source "$lang_dir/${lang}.sh" 2>/dev/null || {
        # ── Complete English fallback (works without lang files) ──
        MSG_MAIN_MENU="MAIN MENU"
        MSG_MENU_WEBSITE="Website Management"
        MSG_MENU_DATABASE="Database Management"
        MSG_MENU_SSL="SSL Certificate"
        MSG_MENU_BACKUP="Backup & Restore"
        MSG_MENU_SECURITY="Security & WAF"
        MSG_MENU_PERFORMANCE="Performance & Speed"
        MSG_MENU_CLUSTER="VPS Cluster Sync"
        MSG_MENU_MONITORING="Monitoring & Logs"
        MSG_MENU_SYSTEM="System Settings"
        MSG_MENU_QUICK="Quick Tools"
        MSG_MENU_MULTIIP="Multi-IP Management"
        MSG_MENU_UPDATE="VPS Update & Tools"
        MSG_MENU_EXIT="Exit"
        MSG_SELECT="Select"
        MSG_BACK="Back"
        MSG_PRESS_ENTER="Press Enter to continue..."
        MSG_INVALID="Invalid choice"
        MSG_SYS_TITLE="SYSTEM SETTINGS"
        MSG_SYS_INFO="System info"
        MSG_SYS_UPDATE="Update system packages"
        MSG_SYS_RESTART="Restart all services"
        MSG_SYS_TG_CONFIG="Edit Telegram config"
        MSG_SYS_CRON_VIEW="View crontab"
        MSG_SYS_CRON_EDIT="Edit crontab"
        MSG_SYS_CONFIG="Show VPS config"
        MSG_SYS_LANG="Change Language"
        MSG_SYS_LANG_CHANGED="Language changed to"
        MSG_SYS_RESTARTED="All services restarted"
        MSG_SYS_TG_TOKEN="Telegram Bot Token"
        MSG_SYS_TG_CHAT="Chat ID"
        MSG_SYS_TG_UPDATED="Telegram config updated"
        MSG_DETAIL_HINT="?  Detail  |  N?  Detail option N"
        MSG_DETAIL_MAIN_1="Add/remove websites, redirect domains, fix permissions, maintenance, plugins. ✅ Safe."
        MSG_DETAIL_MAIN_2="Backup tables, restore, create/drop databases, optimize, import/export SQL. ⚠ Backup first."
        MSG_DETAIL_MAIN_3="Auto-install free SSL via Let's Encrypt. Renew, revoke, force HTTPS. ✅ Safe."
        MSG_DETAIL_MAIN_4="Full backup, scheduled cron, per-table, interactive restore. ✅ Never deletes originals."
        MSG_DETAIL_MAIN_5="WAF, IP lists, rate limiting, fail2ban, headers, anti-brute force. ✅ Safe."
        MSG_DETAIL_MAIN_6="Redis, OPcache, FastCGI, Gzip/Brotli, PHP workers. ✅ Safe."
        MSG_DETAIL_MAIN_7="Multi-VPS nodes, sync backups, migrate sites. ⚠ SSH keys required."
        MSG_DETAIL_MAIN_8="Resource usage, logs, slow queries, Telegram alerts. ✅ Read-only."
        MSG_DETAIL_MAIN_9="System info, update packages, restart services, crontab. ⚠ May restart."
        MSG_DETAIL_MAIN_10="Malware scan, firewall, disk cleanup, swap, SSH, staging, creds."
        MSG_DETAIL_MAIN_11="Multi-IP for SEO or separate SSL. ⚠ Extra IPs needed."
        MSG_DETAIL_MAIN_12="Smart install, update, audit, health check, WP auto-update. ✅ Safe."
        MSG_DETAIL_MAIN_13="Switch language: EN/VI/ZH/JA/FR/ES/PT. Auto-downloads. ✅ Safe."
    }
}

change_language() {
    echo -e "\n${WHITE}${BOLD}  🌍 Change Language${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} 🇬🇧 English"
    echo -e "  ${CYAN}2.${NC} 🇻🇳 Tiếng Việt"
    echo -e "  ${CYAN}3.${NC} 🇨🇳 中文"
    echo -e "  ${CYAN}4.${NC} 🇯🇵 日本語"
    echo -e "  ${CYAN}5.${NC} 🇫🇷 Français"
    echo -e "  ${CYAN}6.${NC} 🇪🇸 Español"
    echo -e "  ${CYAN}7.${NC} 🇧🇷 Português"
    echo ""
    read -p "  Select [1-7]: " _lang_pick
    case "$_lang_pick" in
        1) VPS_LANG="en" ;; 2) VPS_LANG="vi" ;; 3) VPS_LANG="zh" ;;
        4) VPS_LANG="ja" ;; 5) VPS_LANG="fr" ;; 6) VPS_LANG="es" ;;
        7) VPS_LANG="pt" ;; *) return ;;
    esac

    # Download lang file if missing
    local lang_dir="/usr/local/bin/vps-modules/lang"
    mkdir -p "$lang_dir" 2>/dev/null
    if [ ! -f "$lang_dir/${VPS_LANG}.sh" ]; then
        echo -e "  ${YELLOW}Downloading language file...${NC}"
        curl -fsSL --retry 3 "https://raw.githubusercontent.com/hugnanastore-eng/vps-manager/main/scripts/lang/${VPS_LANG}.sh" \
            -o "$lang_dir/${VPS_LANG}.sh" 2>/dev/null
        [ -f "$lang_dir/${VPS_LANG}.sh" ] && chmod +x "$lang_dir/${VPS_LANG}.sh"
    fi

    # Save to config
    if [ -f /root/.vps-config/setup.conf ]; then
        sed -i '/^VPS_LANG=/d' /root/.vps-config/setup.conf
        echo "VPS_LANG=$VPS_LANG" >> /root/.vps-config/setup.conf
    fi
    load_lang
    echo -e "  ${GREEN}✓ Language changed to ${VPS_LANG}${NC}"
    sleep 1
}

load_lang

# ── Input Sanitizer (prevent command injection in sed/eval) ──
_sanitize() {
    # Strip characters that could break sed/shell: | ; & ` $ \ " ' newline
    echo "$1" | tr -d '|;&`$\\"\x27\n\r'
}

# ── MySQL Auth Helper ──
# Uses DB_ROOT_PASS from config; falls back to unix socket auth (no password)
_mysql_auth=""
if [ -n "${DB_ROOT_PASS:-}" ]; then
    # Use defaults-extra-file to avoid password in ps output
    _my_cnf=$(mktemp /tmp/.my.cnf.XXXXXX)
    chmod 600 "$_my_cnf"
    cat > "$_my_cnf" <<MYCNF
[client]
user=root
password=${DB_ROOT_PASS}
MYCNF
    _mysql_auth="--defaults-extra-file=$_my_cnf"
    trap 'rm -f "$_my_cnf"' EXIT
else
    # Try unix socket auth (default on Ubuntu/Debian for root)
    _mysql_auth="-uroot"
fi
_mysql()     { mysql     $_mysql_auth "$@" 2>/dev/null; }
_mysqldump() { mysqldump $_mysql_auth --single-transaction "$@" 2>/dev/null; }

# Auto-detect SERVER_IP if not set in config
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -v '^$' | head -1)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    if [ -z "$SERVER_IP" ]; then
        _ip=$(curl -s --max-time 3 ifconfig.me 2>/dev/null)
        # Validate IP format to prevent injection from DNS hijack
        [[ "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && SERVER_IP="$_ip"
        unset _ip
    fi
    [ -z "$SERVER_IP" ] && SERVER_IP="N/A"
fi

# Auto-detect VPS_NAME if not set in config
[ -z "$VPS_NAME" ] && VPS_NAME=$(hostname -s 2>/dev/null || echo "vps")

# Load modules
for _mod in /usr/local/bin/vps-modules/*.sh; do
    [ -f "$_mod" ] && source "$_mod"
done
unset _mod

# Load extended modules (new features)
for _mod in /usr/local/bin/vps-modules/backup_split.sh \
            /usr/local/bin/vps-modules/wp_auto_update.sh \
            /usr/local/bin/vps-modules/resource_alert.sh \
            /usr/local/bin/vps-modules/disk_cleanup.sh \
            /usr/local/bin/vps-modules/ssh_key_manager.sh \
            /usr/local/bin/vps-modules/domain_health.sh \
            /usr/local/bin/vps-modules/wp_staging.sh \
            /usr/local/bin/vps-modules/simple_analytics.sh \
            /usr/local/bin/vps-modules/omni_shield.sh \
            /usr/local/bin/vps-modules/redis_cache.sh; do
    [ -f "$_mod" ] && source "$_mod"
done
unset _mod

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

# ── Input Validation ──
validate_domain() {
    local d="$1"
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
        echo -e "${RED}  Invalid domain name${NC}"; return 1
    fi
}
validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${RED}  Invalid IP address${NC}"; return 1
    fi
}
validate_dbname() {
    local n="$1"
    if [[ ! "$n" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${RED}  Invalid name (a-z, 0-9, _ only)${NC}"; return 1
    fi
}
validate_plugin() {
    local p="$1"
    if [[ ! "$p" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}  Invalid plugin name${NC}"; return 1
    fi
}

# ── Domain Picker ──
# Lists all domains, user picks by number. Sets PICKED_DOMAIN.
# Usage: pick_domain "prompt text" || return
#   e.g. pick_domain "Select domain" || return
PICKED_DOMAIN=""
_domain_list=()

_load_domains() {
    _domain_list=()
    # Primary source: $DOMAINS from config
    if [ -n "$DOMAINS" ]; then
        IFS=',' read -ra _doms <<< "$DOMAINS"
        for d in "${_doms[@]}"; do
            d=$(echo "$d" | xargs)
            [ -n "$d" ] && _domain_list+=("$d")
        done
    fi
    # Fallback: scan nginx sites-enabled
    if [ ${#_domain_list[@]} -eq 0 ]; then
        for conf in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
            [ -f "$conf" ] || continue
            local sn=$(grep -m1 'server_name' "$conf" 2>/dev/null | sed 's/server_name//;s/;//;s/www\.//g' | xargs | awk '{print $1}')
            [ -n "$sn" ] && [[ "$sn" != "_" ]] && [[ "$sn" != "localhost" ]] && _domain_list+=("$sn")
        done
        # Deduplicate
        local -A seen=()
        local unique=()
        for d in "${_domain_list[@]}"; do
            [ -z "${seen[$d]+x}" ] && unique+=("$d") && seen[$d]=1
        done
        _domain_list=("${unique[@]}")
    fi
    # Last fallback: scan /home directories
    if [ ${#_domain_list[@]} -eq 0 ]; then
        for dir in /home/*/public_html; do
            [ -d "$dir" ] || continue
            local d=$(basename "$(dirname "$dir")")
            [[ "$d" =~ ^[a-zA-Z0-9] ]] && _domain_list+=("$d")
        done
    fi
}

pick_domain() {
    local prompt="${1:-Select domain}"
    PICKED_DOMAIN=""
    _load_domains

    if [ ${#_domain_list[@]} -eq 0 ]; then
        echo -e "  ${RED}No domains found on this server${NC}"
        return 1
    fi

    echo ""
    echo -e "  ${WHITE}${BOLD}Available domains:${NC}"
    local i=1
    for d in "${_domain_list[@]}"; do
        # Show status indicator if curl is available
        if command -v curl &>/dev/null && [ "$i" -le 10 ]; then
            local code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "https://$d" 2>/dev/null)
            if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
                echo -e "    ${GREEN}$i)${NC} $d ${GREEN}●${NC}"
            else
                echo -e "    ${CYAN}$i)${NC} $d ${RED}●${NC}"
            fi
        else
            echo -e "    ${CYAN}$i)${NC} $d"
        fi
        ((i++))
    done
    echo ""
    read -p "  $prompt [1-${#_domain_list[@]}]: " _pick_num

    # Validate number
    if [[ ! "$_pick_num" =~ ^[0-9]+$ ]] || [ "$_pick_num" -lt 1 ] || [ "$_pick_num" -gt ${#_domain_list[@]} ]; then
        echo -e "  ${RED}Invalid selection${NC}"
        return 1
    fi

    PICKED_DOMAIN="${_domain_list[$((_pick_num-1))]}"
    validate_domain "$PICKED_DOMAIN" || return 1
    return 0
}

header() {
    clear
    local _cpu=$(nproc 2>/dev/null || echo "?")
    local _load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    local _os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}${BOLD}     ⚡ VPS ADMIN PANEL v${VER} — $VPS_NAME      ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} 🖥  ${GREEN}$_os${NC}"
    echo -e "${CYAN}║${NC} 🌐 IP: ${GREEN}$SERVER_IP${NC}  |  ⏱ $(uptime -p 2>/dev/null | head -c 35)"
    echo -e "${CYAN}║${NC} 💾 RAM: $(free -h | awk '/Mem/{printf "%s/%s (%s)", $3, $2, int($3/$2*100)"%"}')"
    echo -e "${CYAN}║${NC} 💿 Disk: $(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')"
    echo -e "${CYAN}║${NC} 🔧 CPU: ${_cpu} cores  |  Load: ${_load}"
    echo -e "${CYAN}║${NC} 📦 PHP: $(php -v 2>/dev/null | head -1 | awk '{print $2}')  |  Nginx: $(nginx -v 2>&1 | awk -F'/' '{print $2}')"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

pause() {
    echo ""
    read -p "$(echo -e ${YELLOW}${MSG_PRESS_ENTER}${NC})" dummy
}

# ── Inline Help System ──
# Type ? in any menu to see all details, or N? for specific option
show_detail() {
    local menu="$1" opt="$2"
    echo ""
    echo -e "${WHITE}${BOLD}  📖 DETAIL: $menu${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    case "$menu" in
    main)
        [[ -z "$opt" || "$opt" == "1" ]] && echo -e "  ${CYAN}1. $MSG_MENU_WEBSITE${NC}\n     $MSG_DETAIL_MAIN_1"
        [[ -z "$opt" || "$opt" == "2" ]] && echo -e "  ${CYAN}2. $MSG_MENU_DATABASE${NC}\n     $MSG_DETAIL_MAIN_2"
        [[ -z "$opt" || "$opt" == "3" ]] && echo -e "  ${CYAN}3. $MSG_MENU_SSL${NC}\n     $MSG_DETAIL_MAIN_3"
        [[ -z "$opt" || "$opt" == "4" ]] && echo -e "  ${CYAN}4. $MSG_MENU_BACKUP${NC}\n     $MSG_DETAIL_MAIN_4"
        [[ -z "$opt" || "$opt" == "5" ]] && echo -e "  ${CYAN}5. $MSG_MENU_SECURITY${NC}\n     $MSG_DETAIL_MAIN_5"
        [[ -z "$opt" || "$opt" == "6" ]] && echo -e "  ${CYAN}6. $MSG_MENU_PERFORMANCE${NC}\n     $MSG_DETAIL_MAIN_6"
        [[ -z "$opt" || "$opt" == "7" ]] && echo -e "  ${CYAN}7. $MSG_MENU_CLUSTER${NC}\n     $MSG_DETAIL_MAIN_7"
        [[ -z "$opt" || "$opt" == "8" ]] && echo -e "  ${CYAN}8. $MSG_MENU_MONITORING${NC}\n     $MSG_DETAIL_MAIN_8"
        [[ -z "$opt" || "$opt" == "9" ]] && echo -e "  ${CYAN}9. $MSG_MENU_SYSTEM${NC}\n     $MSG_DETAIL_MAIN_9"
        [[ -z "$opt" || "$opt" == "10" ]] && echo -e "  ${MAGENTA}10. $MSG_MENU_QUICK${NC}\n     $MSG_DETAIL_MAIN_10"
        [[ -z "$opt" || "$opt" == "11" ]] && echo -e "  ${MAGENTA}11. $MSG_MENU_MULTIIP${NC}\n     $MSG_DETAIL_MAIN_11"
        [[ -z "$opt" || "$opt" == "12" ]] && echo -e "  ${YELLOW}12. $MSG_MENU_UPDATE${NC}\n     $MSG_DETAIL_MAIN_12"
        [[ -z "$opt" || "$opt" == "13" ]] && echo -e "  ${YELLOW}13. 🌍 Change Language${NC}\n     $MSG_DETAIL_MAIN_13"
        ;;
    website)
        [[ -z "$opt" || "$opt" == "a" ]] && echo -e "  ${CYAN}a. $MSG_WEB_ADD${NC}\n     $MSG_DETAIL_WEB_A"
        [[ -z "$opt" || "$opt" == "r" ]] && echo -e "  ${YELLOW}r. $MSG_WEB_REMOVE${NC}\n     $MSG_DETAIL_WEB_R"
        [[ -z "$opt" || "$opt" == "d" ]] && echo -e "  ${CYAN}d. $MSG_WEB_REDIRECT${NC}\n     $MSG_DETAIL_WEB_D"
        [[ -z "$opt" || "$opt" == "f" ]] && echo -e "  ${CYAN}f. $MSG_WEB_PERMS${NC}\n     $MSG_DETAIL_WEB_F"
        [[ -z "$opt" || "$opt" == "m" ]] && echo -e "  ${CYAN}m. $MSG_WEB_MAINT${NC}\n     $MSG_DETAIL_WEB_M"
        [[ -z "$opt" || "$opt" == "p" ]] && echo -e "  ${CYAN}p. $MSG_WEB_LISTPLUGINS${NC}\n     $MSG_DETAIL_WEB_P"
        [[ -z "$opt" || "$opt" == "-" ]] && echo -e "  ${CYAN}-. $MSG_WEB_DISABLEPLUGIN${NC}\n     $MSG_DETAIL_WEB_MINUS"
        [[ -z "$opt" || "$opt" == "+" ]] && echo -e "  ${CYAN}+. $MSG_WEB_ENABLEPLUGIN${NC}\n     $MSG_DETAIL_WEB_PLUS"
        ;;
    database)
        [[ -z "$opt" || "$opt" == "1" ]] && echo -e "  ${CYAN}1. $MSG_DB_LIST${NC}\n     $MSG_DETAIL_DB_1"
        [[ -z "$opt" || "$opt" == "2" ]] && echo -e "  ${CYAN}2. $MSG_DB_CREATE${NC}\n     $MSG_DETAIL_DB_2"
        [[ -z "$opt" || "$opt" == "3" ]] && echo -e "  ${CYAN}3. $MSG_DB_DELETE${NC}\n     $MSG_DETAIL_DB_3"
        [[ -z "$opt" || "$opt" == "4" ]] && echo -e "  ${CYAN}4. $MSG_DB_CREDS${NC}\n     $MSG_DETAIL_DB_4"
        [[ -z "$opt" || "$opt" == "5" ]] && echo -e "  ${CYAN}5. $MSG_DB_OPTIMIZE${NC}\n     $MSG_DETAIL_DB_5"
        [[ -z "$opt" || "$opt" == "6" ]] && echo -e "  ${CYAN}6. $MSG_DB_IMPORT${NC}\n     $MSG_DETAIL_DB_6"
        [[ -z "$opt" || "$opt" == "7" ]] && echo -e "  ${CYAN}7. $MSG_DB_EXPORT${NC}\n     $MSG_DETAIL_DB_7"
        ;;
    backup)
        [[ -z "$opt" || "$opt" == "1" ]] && echo -e "  ${CYAN}1. $MSG_BK_RUN${NC}\n     $MSG_DETAIL_BK_1"
        [[ -z "$opt" || "$opt" == "2" ]] && echo -e "  ${CYAN}2. $MSG_BK_LIST${NC}\n     $MSG_DETAIL_BK_2"
        [[ -z "$opt" || "$opt" == "3" ]] && echo -e "  ${CYAN}3. $MSG_BK_RESTORE${NC}\n     $MSG_DETAIL_BK_3"
        [[ -z "$opt" || "$opt" == "4" ]] && echo -e "  ${CYAN}4. $MSG_BK_SYNC${NC}\n     $MSG_DETAIL_BK_4"
        [[ -z "$opt" || "$opt" == "5" ]] && echo -e "  ${CYAN}5. $MSG_BK_SIZE${NC}\n     $MSG_DETAIL_BK_5"
        [[ -z "$opt" || "$opt" == "6" ]] && echo -e "  ${CYAN}6. Per-table Split Dump${NC}\n     $MSG_DETAIL_BK_6"
        ;;
    security)
        [[ -z "$opt" || "$opt" == "1" ]] && echo -e "  ${CYAN}1. $MSG_SEC_WAF${NC}\n     $MSG_DETAIL_SEC_1"
        [[ -z "$opt" || "$opt" == "2" ]] && echo -e "  ${CYAN}2. $MSG_SEC_INTEGRITY${NC}\n     $MSG_DETAIL_SEC_2"
        [[ -z "$opt" || "$opt" == "3" ]] && echo -e "  ${CYAN}3. $MSG_SEC_F2B${NC}\n     $MSG_DETAIL_SEC_3"
        [[ -z "$opt" || "$opt" == "4" ]] && echo -e "  ${CYAN}4. $MSG_SEC_BAN${NC}\n     $MSG_DETAIL_SEC_4"
        [[ -z "$opt" || "$opt" == "5" ]] && echo -e "  ${CYAN}5. $MSG_SEC_UNBAN${NC}\n     $MSG_DETAIL_SEC_5"
        [[ -z "$opt" || "$opt" == "6" ]] && echo -e "  ${CYAN}6. $MSG_SEC_ATTACKS${NC}\n     $MSG_DETAIL_SEC_6"
        [[ -z "$opt" || "$opt" == "7" ]] && echo -e "  ${CYAN}7. $MSG_SEC_PASSWD${NC}\n     $MSG_DETAIL_SEC_7"
        ;;
    performance)
        [[ -z "$opt" || "$opt" == "1" ]] && echo -e "  ${CYAN}1. $MSG_PERF_SPEED${NC}\n     $MSG_DETAIL_PERF_1"
        [[ -z "$opt" || "$opt" == "2" ]] && echo -e "  ${CYAN}2. $MSG_PERF_PHP${NC}\n     $MSG_DETAIL_PERF_2"
        [[ -z "$opt" || "$opt" == "3" ]] && echo -e "  ${CYAN}3. $MSG_PERF_OPCACHE${NC}\n     $MSG_DETAIL_PERF_3"
        [[ -z "$opt" || "$opt" == "4" ]] && echo -e "  ${CYAN}4. $MSG_PERF_RESTART_PHP${NC}\n     $MSG_DETAIL_PERF_4"
        [[ -z "$opt" || "$opt" == "5" ]] && echo -e "  ${CYAN}5. $MSG_PERF_RESTART_NGINX${NC}\n     $MSG_DETAIL_PERF_5"
        [[ -z "$opt" || "$opt" == "6" ]] && echo -e "  ${CYAN}6. $MSG_PERF_CLEAR_OPCACHE${NC}\n     $MSG_DETAIL_PERF_6"
        [[ -z "$opt" || "$opt" == "7" ]] && echo -e "  ${CYAN}7. $MSG_PERF_TOP${NC}\n     $MSG_DETAIL_PERF_7"
        ;;
    esac
    echo ""
    pause
}


show_main_menu() {
    header
    # ── Website Listing ──
    _load_domains
    if [ ${#_domain_list[@]} -gt 0 ]; then
        echo -e "  ${WHITE}${BOLD}🌐 WordPress Sites (${#_domain_list[@]}):${NC}"
        for _d in "${_domain_list[@]}"; do
            local _ssl=""
            [ -f "/etc/letsencrypt/live/$_d/fullchain.pem" ] && _ssl="${GREEN}🔒${NC}" || _ssl="${RED}⚠${NC}"
            echo -e "     $_ssl ${CYAN}$_d${NC}"
        done
        echo -e "  ${WHITE}─────────────────────────────────${NC}"
    fi
    echo -e "${WHITE}${BOLD}  $MSG_MAIN_MENU${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} $MSG_MENU_WEBSITE"
    echo -e "  ${CYAN}2.${NC} $MSG_MENU_DATABASE"
    echo -e "  ${CYAN}3.${NC} $MSG_MENU_SSL"
    echo -e "  ${CYAN}4.${NC} $MSG_MENU_BACKUP"
    echo -e "  ${CYAN}5.${NC} $MSG_MENU_SECURITY"
    echo -e "  ${CYAN}6.${NC} $MSG_MENU_PERFORMANCE"
    echo -e "  ${CYAN}7.${NC} $MSG_MENU_CLUSTER"
    echo -e "  ${CYAN}8.${NC} $MSG_MENU_MONITORING"
    echo -e "  ${CYAN}9.${NC} $MSG_MENU_SYSTEM"
    echo -e "  ${MAGENTA}10.${NC} $MSG_MENU_QUICK"
    echo -e "  ${MAGENTA}11.${NC} $MSG_MENU_MULTIIP"
    echo -e "  ${YELLOW}12.${NC} $MSG_MENU_UPDATE"
    echo -e "  ${YELLOW}13.${NC} 🌍 Change Language"
    echo -e "  ${GREEN}14.${NC} 🛡️  Omni-Shield (BBR+Swap+Firewall+F2B)"
    echo -e "  ${GREEN}15.${NC} 🗃️  Redis Cache Manager (WordPress)"
    echo -e "  ${RED}0.${NC} $MSG_MENU_EXIT"
    echo -e "  ${WHITE}─────────────────────────────────${NC}"
    echo -e "  ${WHITE}$MSG_DETAIL_HINT${NC}"
    echo ""
    read -p "  $MSG_SELECT [0-15]: " CHOICE
}

# ---- 1. WEBSITE MANAGEMENT ----
menu_website() {
    header
    echo -e "${WHITE}${BOLD}  WEBSITE MANAGEMENT${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    
    # List sites (use _load_domains for auto-detection fallback)
    _load_domains
    echo -e "  ${YELLOW}Current sites:${NC}"
    if [ ${#_domain_list[@]} -eq 0 ]; then
        echo -e "    ${RED}No sites found. Add a site or configure DOMAINS in setup.conf${NC}"
    else
        for d in "${_domain_list[@]}"; do
            CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "https://$d" 2>/dev/null)
            if [ "$CODE" = "200" ] || [ "$CODE" = "301" ]; then
                echo -e "    ${GREEN}●${NC} $d (HTTP $CODE)"
            else
                echo -e "    ${RED}●${NC} $d (HTTP $CODE)"
            fi
        done
    fi
    echo ""
    echo -e "  ${CYAN}a.${NC} Add new website"
    echo -e "  ${CYAN}r.${NC} Remove website"
    echo -e "  ${CYAN}d.${NC} Add redirect domain"
    echo -e "  ${CYAN}f.${NC} Fix permissions"
    echo -e "  ${CYAN}m.${NC} Enable/Disable maintenance"
    echo -e "  ${CYAN}p.${NC} List plugins (per site)"
    echo -e "  ${CYAN}-.${NC} Disable plugin"
    echo -e "  ${CYAN}+.${NC} Enable plugin"
    echo -e "  ${RED}0.${NC} Back"
    echo -e "  ${WHITE}?${NC}  What does each option do?"
    echo ""
    read -p "  Select: " WEB_CHOICE

    case $WEB_CHOICE in
        a|A) add_website ;;
        r|R) remove_website ;;
        d|D) add_redirect ;;
        f|F) fix_permissions ;;
        m|M) toggle_maintenance ;;
        p|P) list_plugins ;;
        -) disable_plugin ;;
        +) enable_plugin ;;
        "?") show_detail website ;;
        *\?) show_detail website "${WEB_CHOICE%?}" ;;
    esac
}

add_website() {
    echo ""
    read -p "  Domain name: " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && return
    validate_domain "$NEW_DOMAIN" || return

    log "Creating $NEW_DOMAIN..."

    # Create dir
    mkdir -p /home/$NEW_DOMAIN/public_html

    # Generate DB credentials
    DB_NAME=$(echo "${NEW_DOMAIN}" | tr '.-' '_' | head -c 12)_$(openssl rand -hex 3)
    DB_USER=$(openssl rand -base64 8 | tr -d '/+=' | head -c 10)
    DB_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)

    _mysql -e "
    CREATE DATABASE \`${DB_NAME}\`;
    CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
    GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
    FLUSH PRIVILEGES;" 2>/dev/null

    echo "${NEW_DOMAIN}: DB=${DB_NAME} USER=${DB_USER} PASS=${DB_PASS}" >> /root/.vps-config/db-credentials.txt
    chmod 600 /root/.vps-config/db-credentials.txt

    # Download WordPress
    cd /home/$NEW_DOMAIN/public_html
    wget -q https://wordpress.org/latest.tar.gz
    tar xzf latest.tar.gz --strip-components=1
    rm -f latest.tar.gz

    cp wp-config-sample.php wp-config.php
    sed -i "s/database_name_here/${DB_NAME}/" wp-config.php
    sed -i "s/username_here/${DB_USER}/" wp-config.php
    sed -i "s/password_here/${DB_PASS}/" wp-config.php

    SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    sed -i '/AUTH_KEY/d; /SECURE_AUTH_KEY/d; /LOGGED_IN_KEY/d; /NONCE_KEY/d; /AUTH_SALT/d; /SECURE_AUTH_SALT/d; /LOGGED_IN_SALT/d; /NONCE_SALT/d' wp-config.php
    sed -i "/define.*DB_COLLATE/a\\
${SALTS}" wp-config.php

    cat >> wp-config.php << 'EOF'
define('DISABLE_WP_CRON', true);
define('WP_POST_REVISIONS', 3);
define('AUTOSAVE_INTERVAL', 300);
define('EMPTY_TRASH_DAYS', 7);
EOF

    # Install SEO mu-plugin
    mkdir -p wp-content/mu-plugins
    cp /home/${DOMS[0]}/public_html/wp-content/mu-plugins/seo-essentials.php wp-content/mu-plugins/ 2>/dev/null

    # robots.txt
    cat > robots.txt << ROBOTS
User-agent: *
Allow: /
Disallow: /wp-admin/
Sitemap: https://${NEW_DOMAIN}/wp-sitemap.xml
ROBOTS

    # Nginx vhost
    PHP_SOCK=$(find /run -name "*.sock" -path "*php*" 2>/dev/null | head -1)
    cat > /etc/nginx/conf.d/${NEW_DOMAIN}.conf << VHOST
server {
    listen 80;
    server_name ${NEW_DOMAIN} www.${NEW_DOMAIN};
    root /home/${NEW_DOMAIN}/public_html;
    index index.php index.html;
    include /etc/nginx/performance_headers.conf;
    if (\$waf_block_qs) { return 403; }
    if (\$waf_block_ua) { return 403; }
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location = /wp-config.php { deny all; }
    location = /xmlrpc.php { deny all; }
    location ~ /\. { deny all; }
    location ~* /wp-content/uploads/.*\.php\$ { deny all; }
}
VHOST

    # Set permissions
    chown -R nginx:nginx /home/$NEW_DOMAIN/public_html 2>/dev/null || chown -R www-data:www-data /home/$NEW_DOMAIN/public_html
    find /home/$NEW_DOMAIN/public_html -type d -exec chmod 755 {} \;
    find /home/$NEW_DOMAIN/public_html -type f -exec chmod 644 {} \;

    # Add cron
    (crontab -l 2>/dev/null; echo "*/5 * * * * cd /home/$NEW_DOMAIN/public_html && php wp-cron.php > /dev/null 2>&1") | sort -u | crontab -

    # Update config
    sed -i "s/DOMAINS=\".*\"/DOMAINS=\"${DOMAINS_INPUT},${NEW_DOMAIN}\"/" /root/.vps-config/setup.conf
    source /root/.vps-config/setup.conf

    nginx -t && nginx -s reload

    echo -e "${GREEN}  ✓ $NEW_DOMAIN created!${NC}"
    echo -e "  DB: $DB_NAME | User: $DB_USER | Pass: $DB_PASS"
    echo -e "  Next: Point DNS to $SERVER_IP, then run 'vps-admin' > SSL"
    pause
}

remove_website() {
    pick_domain "Domain to remove" || return
    DEL_DOMAIN="$PICKED_DOMAIN"
    read -p "  Are you sure? Backup will be created. (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && return

    # Backup first
    BACKUP_DIR="/backup/removed/${DEL_DOMAIN}_$(date +%Y%m%d)"
    mkdir -p "$BACKUP_DIR"
    cp -r /home/$DEL_DOMAIN "$BACKUP_DIR/"
    DB=$(grep "^$DEL_DOMAIN:" /root/.vps-config/db-credentials.txt 2>/dev/null | grep -oP 'DB=\K\S+')
    [ -n "$DB" ] && _mysqldump "$DB" 2>/dev/null > "$BACKUP_DIR/${DEL_DOMAIN}.sql"

    rm -f /etc/nginx/conf.d/${DEL_DOMAIN}.conf
    nginx -t && nginx -s reload
    echo -e "${GREEN}  ✓ $DEL_DOMAIN removed. Backup at: $BACKUP_DIR${NC}"
    pause
}

add_redirect() {
    read -p "  Source domain (redirect from): " SRC
    validate_domain "$SRC" || return
    read -p "  Target domain (redirect to): " TGT
    validate_domain "$TGT" || return
    cat > /etc/nginx/conf.d/${SRC}.conf << REDIR
server {
    listen 80;
    server_name ${SRC} www.${SRC};
    return 301 https://${TGT}\$request_uri;
}
REDIR
    nginx -t && nginx -s reload
    echo -e "${GREEN}  ✓ $SRC -> $TGT redirect added${NC}"
    pause
}

fix_permissions() {
    pick_domain "Fix permissions for" || return
    PERM_DOMAIN="$PICKED_DOMAIN"
    chown -R nginx:nginx /home/$PERM_DOMAIN/public_html 2>/dev/null || chown -R www-data:www-data /home/$PERM_DOMAIN/public_html
    find /home/$PERM_DOMAIN/public_html -type d -exec chmod 755 {} \;
    find /home/$PERM_DOMAIN/public_html -type f -exec chmod 644 {} \;
    echo -e "${GREEN}  ✓ Permissions fixed for $PERM_DOMAIN${NC}"
    pause
}

toggle_maintenance() {
    pick_domain "Toggle maintenance for" || return
    MAINT_DOMAIN="$PICKED_DOMAIN"
    MAINT_FILE="/home/$MAINT_DOMAIN/public_html/.maintenance"
    if [ -f "$MAINT_FILE" ]; then
        rm "$MAINT_FILE"
        echo -e "${GREEN}  ✓ Maintenance mode OFF for $MAINT_DOMAIN${NC}"
    else
        echo '<?php $upgrading = time(); ?>' > "$MAINT_FILE"
        echo -e "${YELLOW}  ✓ Maintenance mode ON for $MAINT_DOMAIN${NC}"
    fi
    pause
}

list_plugins() {
    pick_domain "List plugins for" || return
    PL_DOMAIN="$PICKED_DOMAIN"
    echo -e "\n  ${WHITE}Active plugins:${NC}"
    ls /home/$PL_DOMAIN/public_html/wp-content/plugins/ 2>/dev/null | grep -v ".disabled" | grep -v index | while read p; do
        echo -e "    ${GREEN}●${NC} $p"
    done
    echo -e "\n  ${WHITE}Disabled plugins:${NC}"
    ls /home/$PL_DOMAIN/public_html/wp-content/plugins/ 2>/dev/null | grep ".disabled" | while read p; do
        echo -e "    ${RED}○${NC} $p"
    done
    pause
}

disable_plugin() {
    pick_domain "Disable plugin on" || return
    DP_DOMAIN="$PICKED_DOMAIN"
    read -p "  Plugin name: " DP_PLUGIN
    validate_plugin "$DP_PLUGIN" || return
    mv /home/$DP_DOMAIN/public_html/wp-content/plugins/$DP_PLUGIN /home/$DP_DOMAIN/public_html/wp-content/plugins/${DP_PLUGIN}.disabled 2>/dev/null
    echo -e "${GREEN}  ✓ $DP_PLUGIN disabled${NC}"
    pause
}

enable_plugin() {
    pick_domain "Enable plugin on" || return
    EP_DOMAIN="$PICKED_DOMAIN"
    read -p "  Plugin name (without .disabled): " EP_PLUGIN
    validate_plugin "$EP_PLUGIN" || return
    mv /home/$EP_DOMAIN/public_html/wp-content/plugins/${EP_PLUGIN}.disabled /home/$EP_DOMAIN/public_html/wp-content/plugins/$EP_PLUGIN 2>/dev/null
    echo -e "${GREEN}  ✓ $EP_PLUGIN enabled${NC}"
    pause
}

# ---- 2. DATABASE MANAGEMENT ----
menu_database() {
    header
    echo -e "${WHITE}${BOLD}  DATABASE MANAGEMENT${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} List databases"
    echo -e "  ${CYAN}2.${NC} Create database"
    echo -e "  ${CYAN}3.${NC} Delete database"
    echo -e "  ${CYAN}4.${NC} Show DB credentials"
    echo -e "  ${CYAN}5.${NC} Optimize all databases"
    echo -e "  ${CYAN}6.${NC} Import SQL file"
    echo -e "  ${CYAN}7.${NC} Export database"
    echo -e "  ${RED}0.${NC} Back"
    echo -e "  ${WHITE}?${NC}  What does each option do?"
    echo ""
    read -p "  Select: " DB_CHOICE

    case $DB_CHOICE in
        1) _mysql -e "SHOW DATABASES" 2>/dev/null; pause ;;
        2) read -p "  DB name: " NDB; read -p "  DB user: " NDBU; read -p "  DB pass: " NDBP
           validate_dbname "$NDB" || break; validate_dbname "$NDBU" || break
           _mysql -e "CREATE DATABASE \`$NDB\`; CREATE USER '$NDBU'@'localhost' IDENTIFIED BY '$NDBP'; GRANT ALL ON \`$NDB\`.* TO '$NDBU'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
           echo -e "${GREEN}  ✓ Database $NDB created${NC}"; pause ;;
        3) read -p "  DB name to delete: " DDB; validate_dbname "$DDB" || break
           read -p "  Confirm (y/N): " C
           [ "$C" = "y" ] && _mysql -e "DROP DATABASE \`$DDB\`" 2>/dev/null && echo -e "${GREEN}  ✓ Deleted${NC}"; pause ;;
        4) cat /root/.vps-config/db-credentials.txt 2>/dev/null; pause ;;
        5) bash /usr/local/bin/db_deep_optimize.sh; echo -e "${GREEN}  ✓ Optimized${NC}"; pause ;;
        6) read -p "  SQL file path: " SQL; read -p "  Target DB: " TDB
           validate_dbname "$TDB" || break
           [ ! -f "$SQL" ] && echo -e "${RED}  File not found${NC}" && break
           _mysql "$TDB" < "$SQL" 2>/dev/null && echo -e "${GREEN}  ✓ Imported${NC}"; pause ;;
        7) read -p "  DB name: " EDB; validate_dbname "$EDB" || break
           read -p "  Output file: " EFILE
           _mysqldump "$EDB" 2>/dev/null > "$EFILE" && echo -e "${GREEN}  ✓ Exported to $EFILE${NC}"; pause ;;
        "?") show_detail database ;;
        *\?) show_detail database "${DB_CHOICE%?}" ;;
    esac
}

# ---- 3. SSL ----
menu_ssl() {
    header
    echo -e "${WHITE}${BOLD}  SSL CERTIFICATE${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} Issue new SSL (Let's Encrypt)"
    echo -e "  ${CYAN}2.${NC} Renew all certificates"
    echo -e "  ${CYAN}3.${NC} List certificates"
    echo -e "  ${CYAN}4.${NC} Check expiry dates"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " SSL_CHOICE

    case $SSL_CHOICE in
        1) pick_domain "Issue SSL for" || break; SD="$PICKED_DOMAIN"
           /root/.acme.sh/acme.sh --issue -d "$SD" -d "www.$SD" --webroot /home/$SD/public_html --keylength ec-256 --force
           mkdir -p /etc/nginx/ssl/$SD
           /root/.acme.sh/acme.sh --install-cert -d "$SD" --key-file /etc/nginx/ssl/$SD/key.pem --fullchain-file /etc/nginx/ssl/$SD/cert.pem --reloadcmd "nginx -s reload"
           echo -e "${GREEN}  ✓ SSL installed for $SD${NC}"; pause ;;
        2) /root/.acme.sh/acme.sh --cron --force; echo -e "${GREEN}  ✓ All renewed${NC}"; pause ;;
        3) /root/.acme.sh/acme.sh --list; pause ;;
        4) _load_domains
           for d in "${_domain_list[@]}"; do
               EXP=$(echo | openssl s_client -servername $d -connect $d:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
               echo "  $d: $EXP"
           done; pause ;;
    esac
}

# ---- 4. BACKUP ----
menu_backup() {
    header
    echo -e "${WHITE}${BOLD}  BACKUP & RESTORE${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} Run full backup now"
    echo -e "  ${CYAN}2.${NC} List backups"
    echo -e "  ${CYAN}3.${NC} Restore database from backup"
    echo -e "  ${CYAN}4.${NC} Sync to backup VPS"
    echo -e "  ${CYAN}5.${NC} Show backup size"
    echo -e "  ${CYAN}6.${NC} 📦 Per-table Split Dump (GB-scale)"
    echo -e "  ${RED}0.${NC} Back"
    echo -e "  ${WHITE}?${NC}  What does each option do?"
    echo ""
    read -p "  Select: " BK_CHOICE

    case $BK_CHOICE in
        1) bash /usr/local/bin/backup_full.sh; echo -e "${GREEN}  ✓ Backup complete${NC}"; pause ;;
        2) echo "  === Database backups ==="; ls -lh /backup/databases/ 2>/dev/null; pause ;;
        3) read -p "  SQL.gz file: " RF; read -p "  Target DB: " RDB
           validate_dbname "$RDB" || break
           [ ! -f "$RF" ] && echo -e "${RED}  File not found${NC}" && break
           gunzip -c "$RF" | _mysql "$RDB" 2>/dev/null
           echo -e "${GREEN}  ✓ Restored${NC}"; pause ;;
        4) [ -n "$BACKUP_VPS_IP" ] && rsync -azP /backup/ root@${BACKUP_VPS_IP}:/backup/from-${VPS_NAME}/ 2>/dev/null
           echo -e "${GREEN}  ✓ Synced${NC}"; pause ;;
        5) du -sh /backup/*/ 2>/dev/null; echo ""; du -sh /backup/ 2>/dev/null; pause ;;
        6) if type menu_backup_split &>/dev/null; then menu_backup_split; else echo -e "${RED}  Module not loaded. Run: vps-update update${NC}"; sleep 2; fi ;;
        "?") show_detail backup ;;
        *\?) show_detail backup "${BK_CHOICE%?}" ;;
    esac
}

# ---- 5. SECURITY ----
menu_security() {
    header
    echo -e "${WHITE}${BOLD}  SECURITY & WAF${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} WAF status & blocked count"
    echo -e "  ${CYAN}2.${NC} Run integrity check now"
    echo -e "  ${CYAN}3.${NC} View fail2ban status"
    echo -e "  ${CYAN}4.${NC} Ban IP address"
    echo -e "  ${CYAN}5.${NC} Unban IP address"
    echo -e "  ${CYAN}6.${NC} View recent attacks"
    echo -e "  ${CYAN}7.${NC} Change SSH password"
    echo -e "  ${RED}0.${NC} Back"
    echo -e "  ${WHITE}?${NC}  What does each option do?"
    echo ""
    read -p "  Select: " SEC_CHOICE

    case $SEC_CHOICE in
        1) BLOCKED=$(grep " 403 " /var/log/nginx/access.log 2>/dev/null | wc -l)
           echo -e "  WAF blocked: ${RED}$BLOCKED${NC} requests today"; pause ;;
        2) bash /usr/local/bin/integrity_check.sh; echo -e "${GREEN}  ✓ Integrity check complete${NC}"; pause ;;
        3) fail2ban-client status 2>/dev/null; pause ;;
        4) read -p "  IP to ban: " BAN_IP; validate_ip "$BAN_IP" || break; fail2ban-client set sshd banip "$BAN_IP" 2>/dev/null
           echo -e "${GREEN}  ✓ $BAN_IP banned${NC}"; pause ;;
        5) read -p "  IP to unban: " UBAN_IP; validate_ip "$UBAN_IP" || break; fail2ban-client set sshd unbanip "$UBAN_IP" 2>/dev/null
           echo -e "${GREEN}  ✓ $UBAN_IP unbanned${NC}"; pause ;;
        6) echo "  === Last 20 blocked requests ==="; grep " 403 " /var/log/nginx/access.log 2>/dev/null | tail -20; pause ;;
        7) passwd; pause ;;
        "?") show_detail security ;;
        *\?) show_detail security "${SEC_CHOICE%?}" ;;
    esac
}

# ---- 6. PERFORMANCE ----
menu_performance() {
    header
    echo -e "${WHITE}${BOLD}  PERFORMANCE & SPEED${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} Speed test all sites"
    echo -e "  ${CYAN}2.${NC} PHP-FPM status"
    echo -e "  ${CYAN}3.${NC} OPcache status"
    echo -e "  ${CYAN}4.${NC} Restart PHP-FPM"
    echo -e "  ${CYAN}5.${NC} Restart Nginx"
    echo -e "  ${CYAN}6.${NC} Clear OPcache"
    echo -e "  ${CYAN}7.${NC} Show top processes"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " PERF_CHOICE

    case $PERF_CHOICE in
        1) _load_domains
           for d in "${_domain_list[@]}"; do
               TTFB=$(curl -s -o /dev/null -w "%{time_starttransfer}" --connect-timeout 10 "https://$d" 2>/dev/null)
               if (( $(echo "$TTFB < 0.5" | bc -l 2>/dev/null) )); then C="${GREEN}"; elif (( $(echo "$TTFB < 1.0" | bc -l 2>/dev/null) )); then C="${YELLOW}"; else C="${RED}"; fi
               echo -e "  $d: ${C}${TTFB}s${NC}"
           done; pause ;;
        2) systemctl status php-fpm 2>/dev/null || systemctl status php8.1-fpm 2>/dev/null; pause ;;
        3)
            echo ""
            echo -e "  ${WHITE}${BOLD}📊 OPcache Status${NC}"
            echo -e "  ${GREEN}─────────────────────────────────${NC}"
            php -r '
                $s = opcache_get_status(false);
                if (!$s) { echo "  OPcache is disabled\n"; exit; }
                $m = $s["memory_usage"];
                $st = $s["opcache_statistics"];
                $total = $m["used_memory"] + $m["free_memory"];
                $pct = round($m["used_memory"] / $total * 100, 1);
                echo "  ✅ Enabled: " . ($s["opcache_enabled"] ? "Yes" : "No") . "\n";
                echo "  💾 Memory: " . round($m["used_memory"]/1048576,1) . "M / " . round($total/1048576,1) . "M (" . $pct . "% used)\n";
                echo "  📁 Cached files: " . $st["num_cached_scripts"] . "\n";
                echo "  🎯 Hit rate: " . round($st["opcache_hit_rate"],1) . "%\n";
                echo "  ✅ Hits: " . number_format($st["hits"]) . "  |  ❌ Misses: " . number_format($st["misses"]) . "\n";
                echo "  🔄 Restarts: " . $st["oom_restarts"] . " (OOM) / " . $st["manual_restarts"] . " (manual)\n";
                if ($s["cache_full"]) echo "  ⚠️  Cache is FULL!\n";
            ' 2>/dev/null || echo -e "  ${RED}OPcache not available${NC}"
            pause ;;
        4) systemctl restart php-fpm 2>/dev/null || systemctl restart php8.1-fpm; echo -e "${GREEN}  ✓ PHP-FPM restarted${NC}"; pause ;;
        5) nginx -t && nginx -s reload; echo -e "${GREEN}  ✓ Nginx reloaded${NC}"; pause ;;
        6) php -r "opcache_reset();" 2>/dev/null; echo -e "${GREEN}  ✓ OPcache cleared${NC}"; pause ;;
        7) top -bn1 | head -20; pause ;;
    esac
}

# ---- 7. VPS CLUSTER SYNC ----
menu_cluster() {
    header
    echo -e "${WHITE}${BOLD}  VPS CLUSTER SYNC${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} Add VPS to cluster"
    echo -e "  ${CYAN}2.${NC} Remove VPS from cluster"
    echo -e "  ${CYAN}3.${NC} List cluster nodes"
    echo -e "  ${CYAN}4.${NC} Sync configs to all nodes"
    echo -e "  ${CYAN}5.${NC} Sync backup to all nodes"
    echo -e "  ${CYAN}6.${NC} Migrate site to another VPS"
    echo -e "  ${CYAN}7.${NC} Cluster health check"
    echo -e "  ${CYAN}8.${NC} Setup auto-sync schedule"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " CL_CHOICE

    case $CL_CHOICE in
        1) cluster_add ;;
        2) cluster_remove ;;
        3) cluster_list ;;
        4) cluster_sync_configs ;;
        5) cluster_sync_backup ;;
        6) cluster_migrate ;;
        7) cluster_health ;;
        8) cluster_auto_sync ;;
    esac
}

cluster_add() {
    read -p "  VPS IP: " CL_IP
    read -p "  VPS name (e.g. vps2): " CL_NAME
    validate_ip "$CL_IP" || return
    validate_dbname "$CL_NAME" || return

    # Test SSH connection
    echo "  Testing SSH connection..."
    ssh -o ConnectTimeout=5 root@$CL_IP "echo 'OK'" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}  Cannot connect. Setup SSH key first:${NC}"
        echo "    ssh-copy-id root@$CL_IP"
        pause; return
    fi

    # Save to cluster config
    mkdir -p /root/.vps-config/cluster
    echo "${CL_NAME}=${CL_IP}" >> /root/.vps-config/cluster/nodes.conf
    echo -e "${GREEN}  ✓ $CL_NAME ($CL_IP) added to cluster${NC}"

    # Exchange SSH keys
    ssh root@$CL_IP "mkdir -p /root/.vps-config/cluster"
    ssh root@$CL_IP "echo '${VPS_NAME}=${SERVER_IP}' >> /root/.vps-config/cluster/nodes.conf"

    # Copy setup script
    read -p "  Install admin panel on $CL_NAME? (y/N): " INSTALL_REMOTE
    if [ "$INSTALL_REMOTE" = "y" ]; then
        scp /usr/local/bin/vps-admin root@$CL_IP:/usr/local/bin/vps-admin
        ssh root@$CL_IP "chmod +x /usr/local/bin/vps-admin"
        echo -e "${GREEN}  ✓ Admin panel installed on $CL_NAME${NC}"
    fi
    pause
}

cluster_remove() {
    read -p "  VPS name to remove: " CL_NAME
    validate_dbname "$CL_NAME" || return
    sed -i "/^${CL_NAME}=/d" /root/.vps-config/cluster/nodes.conf 2>/dev/null
    echo -e "${GREEN}  ✓ $CL_NAME removed from cluster${NC}"
    pause
}

cluster_list() {
    echo ""
    echo -e "  ${WHITE}Cluster nodes:${NC}"
    echo -e "  ${GREEN}● ${VPS_NAME}${NC} (this) - $SERVER_IP"
    if [ -f /root/.vps-config/cluster/nodes.conf ]; then
        while IFS='=' read -r name ip; do
            [ -z "$name" ] && continue
            ALIVE=$(ssh -o ConnectTimeout=3 root@$ip "echo OK" 2>/dev/null)
            if [ "$ALIVE" = "OK" ]; then
                echo -e "  ${GREEN}●${NC} $name - $ip"
            else
                echo -e "  ${RED}●${NC} $name - $ip (offline)"
            fi
        done < /root/.vps-config/cluster/nodes.conf
    else
        echo -e "  ${YELLOW}  No other nodes configured${NC}"
    fi
    pause
}

cluster_sync_configs() {
    [ ! -f /root/.vps-config/cluster/nodes.conf ] && echo "  No cluster nodes" && pause && return

    echo "  Syncing configs to all nodes..."
    while IFS='=' read -r name ip; do
        [ -z "$name" ] && continue
        rsync -az /etc/nginx/ root@$ip:/backup/from-${VPS_NAME}/nginx/ 2>/dev/null
        rsync -az /usr/local/bin/ root@$ip:/backup/from-${VPS_NAME}/scripts/ 2>/dev/null
        rsync -az /root/.vps-config/ root@$ip:/backup/from-${VPS_NAME}/config/ 2>/dev/null
        echo -e "  ${GREEN}✓${NC} $name synced"
    done < /root/.vps-config/cluster/nodes.conf
    echo -e "${GREEN}  ✓ All nodes synced${NC}"
    pause
}

cluster_sync_backup() {
    [ ! -f /root/.vps-config/cluster/nodes.conf ] && echo "  No cluster nodes" && pause && return

    echo "  Syncing backups to all nodes..."
    while IFS='=' read -r name ip; do
        [ -z "$name" ] && continue
        rsync -azP /backup/ root@$ip:/backup/from-${VPS_NAME}/ 2>/dev/null
        echo -e "  ${GREEN}✓${NC} $name: backup synced"
    done < /root/.vps-config/cluster/nodes.conf
    pause
}

cluster_migrate() {
    pick_domain "Domain to migrate" || return
    MIG_DOMAIN="$PICKED_DOMAIN"
    read -p "  Target VPS name: " MIG_TARGET
    validate_dbname "$MIG_TARGET" || return

    TGT_IP=$(grep "^${MIG_TARGET}=" /root/.vps-config/cluster/nodes.conf 2>/dev/null | cut -d= -f2)
    [ -z "$TGT_IP" ] && echo -e "${RED}  Target not found in cluster${NC}" && pause && return

    echo "  Migrating $MIG_DOMAIN to $MIG_TARGET ($TGT_IP)..."

    # 1. Export DB
    DB=$(grep "^$MIG_DOMAIN:" /root/.vps-config/db-credentials.txt 2>/dev/null | grep -oP 'DB=\K\S+')
    DB_USER_MIG=$(grep "^$MIG_DOMAIN:" /root/.vps-config/db-credentials.txt 2>/dev/null | grep -oP 'USER=\K\S+')
    DB_PASS_MIG=$(grep "^$MIG_DOMAIN:" /root/.vps-config/db-credentials.txt 2>/dev/null | grep -oP 'PASS=\K\S+')
    local _mig_tmp=$(mktemp /tmp/migrate_XXXXXX.sql.gz)
    _mysqldump "$DB" 2>/dev/null | gzip > "$_mig_tmp"

    # 2. Sync files
    rsync -azP /home/$MIG_DOMAIN/ root@$TGT_IP:/home/$MIG_DOMAIN/
    local _remote_tmp="/tmp/migrate_${MIG_DOMAIN}_$$.sql.gz"
    scp "$_mig_tmp" root@$TGT_IP:"$_remote_tmp"
    scp /etc/nginx/conf.d/${MIG_DOMAIN}.conf root@$TGT_IP:/etc/nginx/conf.d/

    # 3. Import DB on target
    ssh root@$TGT_IP "
    source /root/.vps-config/setup.conf 2>/dev/null
    mysql -uroot -p\"\$DB_ROOT_PASS\" -e \"CREATE DATABASE IF NOT EXISTS \\\`$DB\\\`; CREATE USER IF NOT EXISTS '$DB_USER_MIG'@'localhost' IDENTIFIED BY '$DB_PASS_MIG'; GRANT ALL ON \\\`$DB\\\`.* TO '$DB_USER_MIG'@'localhost'; FLUSH PRIVILEGES;\" 2>/dev/null
    gunzip -c '$_remote_tmp' | mysql -uroot -p\"\$DB_ROOT_PASS\" '$DB' 2>/dev/null
    chown -R nginx:nginx /home/$MIG_DOMAIN/ 2>/dev/null || chown -R www-data:www-data /home/$MIG_DOMAIN/
    nginx -t && nginx -s reload
    rm -f '$_remote_tmp'
    " 2>/dev/null

    rm -f "$_mig_tmp"

    echo -e "${GREEN}  ✓ $MIG_DOMAIN migrated to $MIG_TARGET${NC}"
    echo -e "  ${YELLOW}Don't forget to update DNS to point to $TGT_IP${NC}"
    pause
}

cluster_health() {
    echo ""
    echo -e "  ${WHITE}=== Cluster Health ===${NC}"
    echo -e "  ${GREEN}● LOCAL ($VPS_NAME)${NC}"
    echo "    RAM: $(free -h | awk '/Mem/{print $3"/"$2}')"
    echo "    Disk: $(df -h / | awk 'NR==2{print $3"/"$2}')"
    echo "    Load: $(uptime | awk -F'average:' '{print $2}')"

    if [ -f /root/.vps-config/cluster/nodes.conf ]; then
        while IFS='=' read -r name ip; do
            [ -z "$name" ] && continue
            HEALTH=$(ssh -o ConnectTimeout=5 root@$ip "echo RAM=\$(free -h | awk '/Mem/{print \$3\"/\"\$2}') DISK=\$(df -h / | awk 'NR==2{print \$3\"/\"\$2}') LOAD=\$(uptime | awk -F'average:' '{print \$2}')" 2>/dev/null)
            if [ -n "$HEALTH" ]; then
                echo -e "  ${GREEN}● $name ($ip)${NC}"
                echo "    $HEALTH"
            else
                echo -e "  ${RED}● $name ($ip) - OFFLINE${NC}"
            fi
        done < /root/.vps-config/cluster/nodes.conf
    fi
    pause
}

cluster_auto_sync() {
    echo ""
    read -p "  Sync interval (hours, default 6): " INTERVAL
    [ -z "$INTERVAL" ] && INTERVAL=6

    # Add cron for cluster sync
    EXISTING=$(crontab -l 2>/dev/null | grep -v "cluster_sync")
    (echo "$EXISTING"; echo "0 */$INTERVAL * * * /usr/local/bin/vps-admin cluster-sync >> /var/log/cluster_sync.log 2>&1") | crontab -
    echo -e "${GREEN}  ✓ Auto-sync every ${INTERVAL}h configured${NC}"
    pause
}

# ---- 8. MONITORING ----
menu_monitoring() {
    header
    echo -e "${WHITE}${BOLD}  MONITORING & LOGS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} Site status (all)"
    echo -e "  ${CYAN}2.${NC} View site error logs"
    echo -e "  ${CYAN}3.${NC} View nginx access log"
    echo -e "  ${CYAN}4.${NC} View backup log"
    echo -e "  ${CYAN}5.${NC} View integrity log"
    echo -e "  ${CYAN}6.${NC} Send test Telegram alert"
    echo -e "  ${CYAN}7.${NC} Disk usage by site"
    echo -e "  ${CYAN}8.${NC} 📊 Domain Health Dashboard"
    echo -e "  ${CYAN}9.${NC} 📈 Simple Analytics"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " MON_CHOICE

    case $MON_CHOICE in
        1) _load_domains
           for d in "${_domain_list[@]}"; do
               CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://$d" 2>/dev/null)
               TTFB=$(curl -s -o /dev/null -w "%{time_starttransfer}" --connect-timeout 5 "https://$d" 2>/dev/null)
               echo -e "  $d: HTTP $CODE | TTFB: ${TTFB}s"
           done; pause ;;
        2) pick_domain "View debug log for" || break; LD="$PICKED_DOMAIN"; tail -30 /home/$LD/public_html/wp-content/debug.log 2>/dev/null || echo "  No debug.log"; pause ;;
        3) tail -30 /var/log/nginx/access.log; pause ;;
        4) tail -30 /var/log/backup.log 2>/dev/null; pause ;;
        5) tail -30 /var/log/integrity.log 2>/dev/null; pause ;;
        6) bash /usr/local/bin/tg_alert.sh "[TEST] $VPS_NAME: Admin panel test alert" 2>/dev/null
           echo -e "${GREEN}  ✓ Test alert sent${NC}"; pause ;;
        7) _load_domains
           for d in "${_domain_list[@]}"; do
               SIZE=$(du -sh /home/$d/ 2>/dev/null | awk '{print $1}')
               echo "  $d: $SIZE"
           done; pause ;;
        8) if type menu_domain_health &>/dev/null; then menu_domain_health; else echo -e "${RED}  Module not loaded${NC}"; sleep 2; fi ;;
        9) if type menu_simple_analytics &>/dev/null; then menu_simple_analytics; else echo -e "${RED}  Module not loaded${NC}"; sleep 2; fi ;;
    esac
}

# ---- 9. SYSTEM ----
menu_system() {
    header
    echo -e "${WHITE}${BOLD}  $MSG_SYS_TITLE${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}1.${NC} $MSG_SYS_INFO"
    echo -e "  ${CYAN}2.${NC} $MSG_SYS_UPDATE"
    echo -e "  ${CYAN}3.${NC} $MSG_SYS_RESTART"
    echo -e "  ${CYAN}4.${NC} $MSG_SYS_TG_CONFIG"
    echo -e "  ${CYAN}5.${NC} $MSG_SYS_CRON_VIEW"
    echo -e "  ${CYAN}6.${NC} $MSG_SYS_CRON_EDIT"
    echo -e "  ${CYAN}7.${NC} $MSG_SYS_CONFIG"
    echo -e "  ${YELLOW}8.${NC} 🌍 $MSG_SYS_LANG"
    echo -e "  ${RED}0.${NC} $MSG_BACK"
    echo ""
    read -p "  $MSG_SELECT: " SYS_CHOICE

    case $SYS_CHOICE in
        1) echo ""; uname -a; echo ""; free -h; echo ""; df -h; echo ""; uptime; pause ;;
        2) if [ "$OS" = "rocky" ]; then dnf update -y; else apt-get update && apt-get upgrade -y; fi; pause ;;
        3) systemctl restart nginx; systemctl restart php-fpm 2>/dev/null || systemctl restart php8.1-fpm; systemctl restart mariadb
           echo -e "${GREEN}  ✓ $MSG_SYS_RESTARTED${NC}"; pause ;;
        4) read -p "  $MSG_SYS_TG_TOKEN: " NT; read -p "  $MSG_SYS_TG_CHAT: " NCHAT
           NT=$(_sanitize "$NT"); NCHAT=$(_sanitize "$NCHAT")
           sed -i '/^TG_TOKEN=/d;/^TG_CHAT=/d' /root/.vps-config/setup.conf
           echo "TG_TOKEN=\"$NT\"" >> /root/.vps-config/setup.conf
           echo "TG_CHAT=\"$NCHAT\"" >> /root/.vps-config/setup.conf
           if [ -f /usr/local/bin/tg_alert.sh ]; then
               sed -i '/^TOKEN=/d;/^CHAT=/d' /usr/local/bin/tg_alert.sh
               sed -i "2i TOKEN=\"$NT\"\nCHAT=\"$NCHAT\"" /usr/local/bin/tg_alert.sh
           fi
           echo -e "${GREEN}  ✓ $MSG_SYS_TG_UPDATED${NC}"; pause ;;
        5) crontab -l; pause ;;
        6) crontab -e ;;
        7) cat /root/.vps-config/setup.conf 2>/dev/null; pause ;;
        8) change_language; pause ;;
    esac
}

# ---- 10. QUICK TOOLS ----
menu_quick_tools() {
    header
    echo -e "${WHITE}${BOLD}  ⚡ QUICK TOOLS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"

    # Show Telegram status
    local _tg_status="${RED}✗ Not configured${NC}"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        _tg_status="${GREEN}✓ Active${NC}"
    fi
    echo -e "  📟 Telegram: ${_tg_status}"
    echo ""

    echo -e "  ${YELLOW}13.${NC} 📟 Telegram Bot Config"
    echo -e "  ${CYAN}1.${NC} 🛡️  Malware Scanner (quét WP)"
    echo -e "  ${CYAN}2.${NC} 🔥 Firewall Hardening"
    echo -e "  ${CYAN}3.${NC} 📦 Interactive Backup Restore"
    echo -e "  ${CYAN}4.${NC} 🧹 Disk Cleanup"
    echo -e "  ${CYAN}5.${NC} 🔄 Swap Management"
    echo -e "  ${CYAN}6.${NC} 📊 Resource Alerts"
    echo -e "  ${CYAN}7.${NC} 🌐 WordPress Bulk Operations"
    echo -e "  ${CYAN}8.${NC} 📋 View Site Credentials"
    echo -e "  ${CYAN}9.${NC} 🔑 Change Root Password"
    echo -e "  ${CYAN}10.${NC} ⬆️  WordPress Auto-Update"
    echo -e "  ${CYAN}11.${NC} 🔑 SSH Key Manager"
    echo -e "  ${CYAN}12.${NC} 🔄 WordPress Staging"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " QT_CHOICE

    case $QT_CHOICE in
        13) configure_telegram ;; 
        1) vps-update malware-scan; pause ;;
        2) vps-update firewall; pause ;;
        3) interactive_restore ;;
        4) if type menu_disk_cleanup &>/dev/null; then menu_disk_cleanup; else disk_cleanup; fi ;;
        5) swap_management ;;
        6) if type menu_resource_alert &>/dev/null; then menu_resource_alert; else resource_alerts; fi ;;
        7) wp_bulk_ops ;;
        8) view_credentials ;;
        9) change_root_pass ;;
        10) if type menu_wp_update &>/dev/null; then menu_wp_update; else echo -e "${RED}  Module not loaded. Run: vps-update update${NC}"; sleep 2; fi ;;
        11) if type menu_ssh_keys &>/dev/null; then menu_ssh_keys; else echo -e "${RED}  Module not loaded. Run: vps-update update${NC}"; sleep 2; fi ;;
        12) if type menu_wp_staging &>/dev/null; then menu_wp_staging; else echo -e "${RED}  Module not loaded. Run: vps-update update${NC}"; sleep 2; fi ;;
    esac
}

configure_telegram() {
    echo ""
    echo -e "${WHITE}${BOLD}  📟 TELEGRAM BOT CONFIG${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"

    # Show current status
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        echo -e "  Status: ${GREEN}✓ Configured${NC}"
        echo -e "  Token:  ${CYAN}${TG_TOKEN:0:10}...${NC}"
        echo -e "  Chat:   ${CYAN}$TG_CHAT${NC}"
        echo ""
        echo -e "  ${CYAN}1.${NC} Update token & chat ID"
        echo -e "  ${CYAN}2.${NC} Send test message"
        echo -e "  ${CYAN}3.${NC} Remove config"
        echo -e "  ${RED}0.${NC} Back"
        echo ""
        read -p "  Select: " _tg_action
        case "$_tg_action" in
            1) _tg_setup ;;
            2) _tg_test ;;
            3) sed -i '/^TG_TOKEN=/d;/^TG_CHAT=/d' /root/.vps-config/setup.conf
               unset TG_TOKEN TG_CHAT
               echo -e "  ${GREEN}✓ Telegram config removed${NC}"; pause ;;
        esac
    else
        echo -e "  Status: ${RED}✗ Not configured${NC}"
        echo ""
        echo "  To get a Telegram Bot Token:"
        echo "    1. Open Telegram > search @BotFather"
        echo "    2. Send /newbot and follow instructions"
        echo "    3. Copy the token"
        echo ""
        echo "  To get your Chat ID:"
        echo "    1. Search @userinfobot on Telegram"
        echo "    2. Send /start — it will reply with your ID"
        echo ""
        _tg_setup
    fi
}

_tg_setup() {
    read -p "  Telegram Bot Token: " _new_token
    read -p "  Chat ID: " _new_chat
    [ -z "$_new_token" ] || [ -z "$_new_chat" ] && { echo -e "  ${RED}Both fields required${NC}"; pause; return; }

    # Sanitize input to prevent injection
    _new_token=$(_sanitize "$_new_token")
    _new_chat=$(_sanitize "$_new_chat")

    # Save to config (delete+append, not sed substitution)
    sed -i '/^TG_TOKEN=/d;/^TG_CHAT=/d' /root/.vps-config/setup.conf 2>/dev/null
    echo "TG_TOKEN=\"$_new_token\"" >> /root/.vps-config/setup.conf
    echo "TG_CHAT=\"$_new_chat\"" >> /root/.vps-config/setup.conf
    export TG_TOKEN="$_new_token"
    export TG_CHAT="$_new_chat"

    # Update tg_alert.sh if exists (safe: delete+insert, no sed substitution)
    if [ -f /usr/local/bin/tg_alert.sh ]; then
        sed -i '/^TOKEN=/d;/^CHAT=/d' /usr/local/bin/tg_alert.sh
        sed -i "2i TOKEN=\"$_new_token\"\nCHAT=\"$_new_chat\"" /usr/local/bin/tg_alert.sh
    fi

    echo -e "  ${GREEN}✓ Telegram configured!${NC}"
    _tg_test
}

_tg_test() {
    echo -e "  Sending test message..."
    local _result=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" -d "text=🟢 VPS Admin ($VPS_NAME) - Test OK! $(date '+%H:%M %d/%m/%Y')" 2>&1)
    if echo "$_result" | grep -q '"ok":true'; then
        echo -e "  ${GREEN}✓ Test message sent! Check your Telegram.${NC}"
    else
        echo -e "  ${RED}✗ Failed! Check token & chat ID.${NC}"
        echo -e "  ${YELLOW}Response: $(echo $_result | head -c 200)${NC}"
    fi
    pause
}

# ---- 12. VPS UPDATE & TOOLS ----
menu_vps_update() {
    header
    echo -e "${WHITE}${BOLD}  🔧 VPS UPDATE & TOOLS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"

    # Show current version
    local cur_ver="unknown"
    [ -f /root/.vps-config/version ] && cur_ver=$(cat /root/.vps-config/version)
    echo -e "  Current version: ${CYAN}v${cur_ver}${NC}"
    echo ""

    echo -e "  ${CYAN}1.${NC} 🚀 Smart Install (full setup)"
    echo -e "  ${CYAN}2.${NC} 🔄 Update Scripts (pull latest)"
    echo -e "  ${CYAN}3.${NC} 🔍 Security Audit"
    echo -e "  ${CYAN}4.${NC} 🛡️  Malware Scanner"
    echo -e "  ${CYAN}5.${NC} 🔥 Firewall Hardening"
    echo -e "  ${CYAN}6.${NC} 🧹 Disk Cleanup"
    echo -e "  ${CYAN}7.${NC} 📟 Resource Check"
    echo -e "  ${CYAN}8.${NC} 🩺 Domain Health Check"
    echo -e "  ${CYAN}9.${NC} ⬆️  WP Auto-Update + Rollback"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " VU_CHOICE

    case $VU_CHOICE in
        1) vps-update smart; pause ;;
        2) vps-update update; pause ;;
        3) vps-update audit; pause ;;
        4) vps-update malware-scan; pause ;;
        5) vps-update firewall; pause ;;
        6) if type menu_disk_cleanup &>/dev/null; then menu_disk_cleanup; else echo -e "${RED}  Module not loaded${NC}"; sleep 2; fi ;;
        7) if type resource_check &>/dev/null; then resource_check; pause; elif type menu_resource_alert &>/dev/null; then menu_resource_alert; else echo -e "${RED}  Module not loaded${NC}"; sleep 2; fi ;;
        8) if type domain_health_dashboard &>/dev/null; then domain_health_dashboard; pause; elif type menu_domain_health &>/dev/null; then menu_domain_health; else echo -e "${RED}  Module not loaded${NC}"; sleep 2; fi ;;
        9) if type menu_wp_update &>/dev/null; then menu_wp_update; else echo -e "${RED}  Module not loaded. Run: vps-update update${NC}"; sleep 2; fi ;;
    esac
}

# ---- Interactive Backup Restore ----
interactive_restore() {
    echo ""
    echo -e "${WHITE}${BOLD}  📦 INTERACTIVE BACKUP RESTORE${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""

    # List available backups
    echo -e "  ${YELLOW}Database backups:${NC}"
    local i=1
    local -a backup_files=()
    
    for f in /backup/databases/*.sql.gz /backup/databases/*.sql; do
        [ -f "$f" ] || continue
        local size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        local date=$(stat -c '%y' "$f" 2>/dev/null | cut -d' ' -f1)
        echo -e "    $i. $(basename $f) (${size}, ${date})"
        backup_files+=("$f")
        ((i++))
    done

    if [ ${#backup_files[@]} -eq 0 ]; then
        echo -e "  ${RED}No backups found in /backup/databases/${NC}"
        pause; return
    fi

    echo ""
    read -p "  Select backup [1-$((i-1))]: " sel
    [ -z "$sel" ] && return
    local idx=$((sel-1))
    [ $idx -lt 0 ] || [ $idx -ge ${#backup_files[@]} ] && echo "Invalid" && pause && return

    local selected="${backup_files[$idx]}"
    echo -e "  Selected: ${CYAN}$(basename $selected)${NC}"

    # List target databases or sites
    echo ""
    echo -e "  ${YELLOW}Target sites:${NC}"
    _load_domains
    local j=1
    for d in "${_domain_list[@]}"; do
        echo "    $j. $d"
        ((j++))
    done

    if [ ${#_domain_list[@]} -eq 0 ]; then
        echo -e "  ${RED}No sites found${NC}"
        pause; return
    fi

    echo ""
    read -p "  Target site [1-$((j-1))]: " tsel
    [ -z "$tsel" ] && return
    if [[ ! "$tsel" =~ ^[0-9]+$ ]] || [ "$tsel" -lt 1 ] || [ "$tsel" -gt ${#_domain_list[@]} ]; then
        echo -e "  ${RED}Invalid selection${NC}"; pause; return
    fi
    local tidx=$((tsel-1))
    local target_domain="${_domain_list[$tidx]}"

    # Get DB name from credentials
    local db_name=$(grep "^$target_domain:" /root/.vps-config/db-credentials.txt 2>/dev/null | grep -oP 'DB=\K\S+')
    if [ -z "$db_name" ] && [ -f "/root/.vps-config/sites/${target_domain}.info" ]; then
        db_name=$(grep "DB_NAME=" "/root/.vps-config/sites/${target_domain}.info" | cut -d= -f2)
    fi

    if [ -z "$db_name" ]; then
        read -p "  Database name for $target_domain: " db_name
        validate_dbname "$db_name" || return
    fi

    echo ""
    echo -e "  ${YELLOW}⚠ This will OVERWRITE database '$db_name' with backup!${NC}"
    read -p "  Confirm restore? (y/N): " confirm
    [ "$confirm" != "y" ] && return

    echo "  Restoring..."
    if [[ "$selected" == *.gz ]]; then
        gunzip -c "$selected" | _mysql "$db_name" 2>/dev/null
    else
        _mysql "$db_name" < "$selected" 2>/dev/null
    fi

    echo -e "  ${GREEN}✓ Database restored from $(basename $selected) → $db_name${NC}"
    pause
}

# ---- Disk Cleanup ----
disk_cleanup() {
    echo ""
    echo -e "${WHITE}${BOLD}  🧹 DISK CLEANUP${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""

    local total_freed=0

    # 1. Old log files
    echo -e "  ${CYAN}[1/6]${NC} Cleaning old logs..."
    local old_logs=$(find /var/log -name '*.gz' -o -name '*.[0-9]' 2>/dev/null | wc -l)
    local log_size=$(find /var/log -name '*.gz' -o -name '*.[0-9]' -exec du -cb {} + 2>/dev/null | tail -1 | awk '{print int($1/1024/1024)}')
    echo "    Found $old_logs rotated log files (~${log_size}MB)"

    # 2. Package cache
    echo -e "  ${CYAN}[2/6]${NC} Package cache..."
    if command -v dnf &>/dev/null; then
        local cache_size=$(du -sh /var/cache/dnf 2>/dev/null | awk '{print $1}')
        echo "    DNF cache: $cache_size"
    elif command -v apt-get &>/dev/null; then
        local cache_size=$(du -sh /var/cache/apt 2>/dev/null | awk '{print $1}')
        echo "    APT cache: $cache_size"
    fi

    # 3. WordPress transients
    echo -e "  ${CYAN}[3/6]${NC} WP transients..."
    local transients=0
    if command -v wp &>/dev/null; then
        for dir in /home/*/public_html; do
            [ -f "$dir/wp-config.php" ] || continue
            local t=$(wp transient delete --all --path="$dir" --allow-root 2>/dev/null | grep -c 'Success')
            transients=$((transients + t))
        done
    fi
    echo "    Cleared transients from $transients sites"

    # 4. WordPress post revisions
    echo -e "  ${CYAN}[4/6]${NC} WP post revisions..."
    if command -v wp &>/dev/null; then
        for dir in /home/*/public_html; do
            [ -f "$dir/wp-config.php" ] || continue
            local domain=$(basename "$(dirname "$dir")")
            local prefix=$(wp db prefix --path="$dir" --allow-root 2>/dev/null)
            local revs=$(wp db query "SELECT COUNT(*) FROM ${prefix}posts WHERE post_type='revision'" --path="$dir" --allow-root 2>/dev/null | tail -1)
            echo "    $domain: $revs revisions"
        done
    fi

    # 5. Old backups (>30 days)
    echo -e "  ${CYAN}[5/6]${NC} Old backups (>30 days)..."
    local old_backups=$(find /backup -name '*.sql.gz' -mtime +30 2>/dev/null | wc -l)
    local old_size=$(find /backup -name '*.sql.gz' -mtime +30 -exec du -cb {} + 2>/dev/null | tail -1 | awk '{print int($1/1024/1024)}')
    echo "    Found $old_backups old backups (~${old_size}MB)"

    # 6. Temp files
    echo -e "  ${CYAN}[6/6]${NC} Temp files..."
    local tmp_size=$(du -sh /tmp 2>/dev/null | awk '{print $1}')
    echo "    /tmp: $tmp_size"

    echo ""
    read -p "  Run cleanup now? (y/N): " do_clean
    if [ "$do_clean" = "y" ]; then
        # Clean rotated logs
        find /var/log -name '*.gz' -delete 2>/dev/null
        find /var/log -name '*.[0-9]' -delete 2>/dev/null
        # Clean package cache
        if command -v dnf &>/dev/null; then
            dnf clean all > /dev/null 2>&1
        elif command -v apt-get &>/dev/null; then
            apt-get clean > /dev/null 2>&1
            apt-get autoremove -y > /dev/null 2>&1
        fi
        # Clean old backups
        read -p "  Delete backups older than 30 days? (y/N): " del_old
        [ "$del_old" = "y" ] && find /backup -name '*.sql.gz' -mtime +30 -delete 2>/dev/null
        # Clean WordPress revisions
        if command -v wp &>/dev/null; then
            for dir in /home/*/public_html; do
                [ -f "$dir/wp-config.php" ] || continue
                local prefix=$(wp db prefix --path="$dir" --allow-root 2>/dev/null)
                wp db query "DELETE FROM ${prefix}posts WHERE post_type='revision'" --path="$dir" --allow-root 2>/dev/null
            done
        fi
        echo -e "  ${GREEN}✓ Cleanup complete!${NC}"
        echo "  Disk after: $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    fi
    pause
}

# ---- Swap Management ----
swap_management() {
    echo ""
    echo -e "${WHITE}${BOLD}  🔄 SWAP MANAGEMENT${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""

    # Current status
    local swap_total=$(free -h | awk '/Swap/{print $2}')
    local swap_used=$(free -h | awk '/Swap/{print $3}')
    echo -e "  Current swap: ${CYAN}${swap_used}${NC} / ${swap_total}"
    swapon --show 2>/dev/null | head -5
    echo ""

    echo -e "  ${CYAN}1.${NC} Create swap (nếu chưa có)"
    echo -e "  ${CYAN}2.${NC} Resize swap"
    echo -e "  ${CYAN}3.${NC} Remove swap"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " sw_choice

    case $sw_choice in
        1|2)
            read -p "  Swap size (GB, default 2): " sw_size
            [ -z "$sw_size" ] && sw_size=2
            # Remove existing swapfile
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile 2>/dev/null
            # Create new
            fallocate -l ${sw_size}G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1G count=$sw_size 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile > /dev/null 2>&1
            swapon /swapfile
            # Persist in fstab
            grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            # Set swappiness
            sysctl vm.swappiness=10 > /dev/null 2>&1
            grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
            echo -e "  ${GREEN}✓ ${sw_size}GB swap created (swappiness=10)${NC}"
            ;;
        3)
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile 2>/dev/null
            sed -i '/swapfile/d' /etc/fstab
            echo -e "  ${GREEN}✓ Swap removed${NC}"
            ;;
    esac
    pause
}

# ---- Resource Alerts ----
resource_alerts() {
    echo ""
    echo -e "${WHITE}${BOLD}  📊 RESOURCE USAGE ALERTS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""

    # RAM
    local ram_pct=$(free | awk '/Mem/{printf "%d", $3/$2*100}')
    local ram_used=$(free -h | awk '/Mem/{print $3}')
    local ram_total=$(free -h | awk '/Mem/{print $2}')
    if [ $ram_pct -gt 90 ]; then
        echo -e "  RAM:  ${RED}⚠ ${ram_pct}% (${ram_used}/${ram_total})${NC}"
    elif [ $ram_pct -gt 70 ]; then
        echo -e "  RAM:  ${YELLOW}● ${ram_pct}% (${ram_used}/${ram_total})${NC}"
    else
        echo -e "  RAM:  ${GREEN}● ${ram_pct}% (${ram_used}/${ram_total})${NC}"
    fi

    # CPU
    local cpu_load=$(uptime | awk -F'average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
    local cpu_cores=$(nproc)
    echo -e "  CPU:  Load $cpu_load (cores: $cpu_cores)"

    # Disk
    local disk_pct=$(df / | awk 'NR==2{gsub(/%/,""); print $5}')
    local disk_used=$(df -h / | awk 'NR==2{print $3}')
    local disk_total=$(df -h / | awk 'NR==2{print $2}')
    if [ "$disk_pct" -gt 90 ]; then
        echo -e "  Disk: ${RED}⚠ ${disk_pct}% (${disk_used}/${disk_total})${NC}"
    elif [ "$disk_pct" -gt 70 ]; then
        echo -e "  Disk: ${YELLOW}● ${disk_pct}% (${disk_used}/${disk_total})${NC}"
    else
        echo -e "  Disk: ${GREEN}● ${disk_pct}% (${disk_used}/${disk_total})${NC}"
    fi

    # Swap
    local swap_total=$(free | awk '/Swap/{print $2}')
    if [ "$swap_total" -gt 0 ]; then
        local swap_pct=$(free | awk '/Swap/{if($2>0) printf "%d", $3/$2*100; else print "0"}')
        echo -e "  Swap: ${swap_pct}%"
    else
        echo -e "  Swap: ${YELLOW}Not configured${NC}"
    fi

    # Top processes
    echo ""
    echo -e "  ${WHITE}Top 5 processes by memory:${NC}"
    ps aux --sort=-%mem | head -6 | awk 'NR>1{printf "    %-8s %5s%%  %s\n", $1, $4, $11}'

    echo ""
    echo -e "  ${WHITE}Top 5 processes by CPU:${NC}"
    ps aux --sort=-%cpu | head -6 | awk 'NR>1{printf "    %-8s %5s%%  %s\n", $1, $3, $11}'

    # Network connections
    echo ""
    local conn=$(ss -tun | wc -l)
    echo -e "  Active connections: $conn"

    # Uptime
    echo -e "  Uptime: $(uptime -p)"

    # Alert thresholds
    echo ""
    if [ $ram_pct -gt 90 ] || [ "$disk_pct" -gt 90 ]; then
        echo -e "  ${RED}${BOLD}⚠ CRITICAL: Resources near capacity!${NC}"
        echo -e "  ${YELLOW}→ Consider upgrading VPS or running Disk Cleanup${NC}"
    elif [ $ram_pct -gt 70 ] || [ "$disk_pct" -gt 70 ]; then
        echo -e "  ${YELLOW}⚠ Warning: Resources moderately used${NC}"
    else
        echo -e "  ${GREEN}✅ All resources within normal limits${NC}"
    fi
    pause
}

# ---- WordPress Bulk Operations ----
wp_bulk_ops() {
    echo ""
    echo -e "${WHITE}${BOLD}  🌐 WORDPRESS BULK OPERATIONS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} Update all plugins (all sites)"
    echo -e "  ${CYAN}2.${NC} Update all themes (all sites)"
    echo -e "  ${CYAN}3.${NC} Update WordPress core (all sites)"
    echo -e "  ${CYAN}4.${NC} Check site health (all sites)"
    echo -e "  ${CYAN}5.${NC} Clear all caches"
    echo -e "  ${CYAN}6.${NC} Deactivate plugin on all sites"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " wp_choice

    if ! command -v wp &>/dev/null; then
        echo -e "  ${RED}WP-CLI not installed. Run 'vps-update install' first.${NC}"
        pause; return
    fi

    case $wp_choice in
        1)
            _load_domains
            for d in "${_domain_list[@]}"; do
                local wp_dir="/home/$d/public_html"
                [ -f "$wp_dir/wp-config.php" ] || continue
                echo -e "  ${CYAN}$d:${NC}"
                wp plugin update --all --path="$wp_dir" --allow-root 2>/dev/null | grep -E 'Success|plugin'
            done; pause ;;
        2)
            _load_domains
            for d in "${_domain_list[@]}"; do
                local wp_dir="/home/$d/public_html"
                [ -f "$wp_dir/wp-config.php" ] || continue
                echo -e "  ${CYAN}$d:${NC}"
                wp theme update --all --path="$wp_dir" --allow-root 2>/dev/null | grep -E 'Success|theme'
            done; pause ;;
        3)
            _load_domains
            for d in "${_domain_list[@]}"; do
                local wp_dir="/home/$d/public_html"
                [ -f "$wp_dir/wp-config.php" ] || continue
                echo -e "  ${CYAN}$d:${NC}"
                wp core update --path="$wp_dir" --allow-root 2>/dev/null | grep -E 'Success|version'
            done; pause ;;
        4)
            echo ""
            _load_domains
            for d in "${_domain_list[@]}"; do
                local wp_dir="/home/$d/public_html"
                [ -f "$wp_dir/wp-config.php" ] || continue
                local version=$(wp core version --path="$wp_dir" --allow-root 2>/dev/null)
                local plugins=$(wp plugin list --status=active --format=count --path="$wp_dir" --allow-root 2>/dev/null)
                local updates=$(wp plugin list --update=available --format=count --path="$wp_dir" --allow-root 2>/dev/null)
                echo -e "  ${WHITE}$d:${NC}"
                echo -e "    WP $version | $plugins plugins | ${YELLOW}$updates updates available${NC}"
            done; pause ;;
        5)
            _load_domains
            for d in "${_domain_list[@]}"; do
                local wp_dir="/home/$d/public_html"
                [ -f "$wp_dir/wp-config.php" ] || continue
                wp cache flush --path="$wp_dir" --allow-root 2>/dev/null
                wp transient delete --all --path="$wp_dir" --allow-root 2>/dev/null
            done
            php -r "opcache_reset();" 2>/dev/null
            echo -e "  ${GREEN}✓ All caches cleared${NC}"; pause ;;
        6)
            read -p "  Plugin slug to deactivate: " slug; validate_plugin "$slug" || break
            _load_domains
            for d in "${_domain_list[@]}"; do
                local wp_dir="/home/$d/public_html"
                [ -f "$wp_dir/wp-config.php" ] || continue
                wp plugin deactivate "$slug" --path="$wp_dir" --allow-root 2>/dev/null
                echo -e "  ${GREEN}✓${NC} $d: $slug deactivated"
            done; pause ;;
    esac
}

# ---- View Credentials ----
view_credentials() {
    echo ""
    echo -e "${WHITE}${BOLD}  📋 SITE CREDENTIALS${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""

    # From new format
    if [ -d /root/.vps-config/sites ]; then
        for f in /root/.vps-config/sites/*.info; do
            [ -f "$f" ] || continue
            echo -e "  ${CYAN}$(basename $f .info):${NC}"
            grep -E 'DB_|DOMAIN|SERVER' "$f" | while read line; do
                echo "    $line"
            done
            echo ""
        done
    fi

    # From old format
    if [ -f /root/.vps-config/db-credentials.txt ]; then
        echo -e "  ${YELLOW}Legacy credentials:${NC}"
        cat /root/.vps-config/db-credentials.txt
        echo ""
    fi

    pause
}

# ---- Change Root Password ----
change_root_pass() {
    echo ""
    echo -e "${WHITE}${BOLD}  🔑 CHANGE ROOT PASSWORD${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠ Khuyến nghị:${NC}"
    echo "    • Ít nhất 16 ký tự"
    echo "    • Gồm: chữ hoa + thường + số + ký tự đặc biệt"
    echo "    • Không dùng thông tin cá nhân"
    echo "    • Lưu lại mật khẩu ở nơi an toàn"
    echo ""
    passwd root
    pause
}

# ========================
# CLI MODE (non-interactive)
# ========================
if [ -n "$1" ]; then
    case "$1" in
        status) menu_monitoring; exit ;;
        speed)
            _load_domains
            for d in "${_domain_list[@]}"; do
                TTFB=$(curl -s -o /dev/null -w "%{time_starttransfer}" --connect-timeout 10 "https://$d" 2>/dev/null)
                echo "$d: TTFB ${TTFB}s"
            done; exit ;;
        backup) bash /usr/local/bin/backup_full.sh; exit ;;
        backup-split) type menu_backup_split &>/dev/null && menu_backup_split; exit ;;
        update) bash /usr/local/bin/wp_auto_update.sh; exit ;;
        wp-update) type wp_update_all &>/dev/null && wp_update_all; exit ;;
        script-update) vps-update update; exit ;;
        malware-scan|malware) vps-update malware-scan "$2"; exit ;;
        cluster-sync) cluster_sync_backup; cluster_sync_configs; exit ;;
        resource-check) type resource_check &>/dev/null && resource_check; exit ;;
        health) type domain_health_dashboard &>/dev/null && domain_health_dashboard; exit ;;
        analytics) type menu_simple_analytics &>/dev/null && menu_simple_analytics; exit ;;
        cleanup) type menu_disk_cleanup &>/dev/null && menu_disk_cleanup; exit ;;
        shield) type menu_omni_shield &>/dev/null && menu_omni_shield; exit ;;
        redis) type menu_redis_cache &>/dev/null && menu_redis_cache; exit ;;
        *) echo "Usage: vps-admin [status|speed|backup|backup-split|update|wp-update|script-update|malware-scan|cluster-sync|resource-check|health|analytics|cleanup|shield|redis]"; exit ;;
    esac
fi

# ========================
# MAIN LOOP
# ========================
while true; do
    show_main_menu
    case $CHOICE in
        1) menu_website ;;
        2) menu_database ;;
        3) menu_ssl ;;
        4) menu_backup ;;
        5) menu_security ;;
        6) menu_performance ;;
        7) menu_cluster ;;
        8) menu_monitoring ;;
        9) menu_system ;;
        10) menu_quick_tools ;;
        11) if type menu_multi_ip &>/dev/null; then menu_multi_ip; else echo -e "${RED}  Module not installed. Run: vps-update update${NC}"; sleep 2; fi ;;
        12) menu_vps_update ;;
        13) change_language ;;
        14) if type menu_omni_shield &>/dev/null; then menu_omni_shield; else echo -e "${RED}  Module not loaded. Run: vps-update update${NC}"; sleep 2; fi ;;
        15) if type menu_redis_cache &>/dev/null; then menu_redis_cache; else echo -e "${RED}  Module not loaded. Run: vps-update update${NC}"; sleep 2; fi ;;
        "?") show_detail main ;;
        *\?) show_detail main "${CHOICE%?}" ;;
        0) echo -e "${GREEN}  Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}  $MSG_INVALID${NC}"; sleep 1 ;;
    esac
done
