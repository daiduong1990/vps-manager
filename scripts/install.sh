#!/bin/bash
# ============================================
#  VPS 1 Chạm - Smart Update / Smart Install
#  Source: https://github.com/hugnanastore-eng/vps-manager
#  Version: 2.1.0
# ============================================
#
# MODES:
#   1. Fresh Install (VPS trắng) - cài tất cả
#   2. Smart Install (VPS đang chạy) - detect & skip existing, add missing
#   3. Update (VPS đã cài script) - so sánh version, update components
#
# COMPATIBLE WITH: HocVPS, aaPanel, CyberPanel, manual LEMP setups
# ============================================

# set -e removed: causes silent exit on piped install (curl|bash)

VERSION="2.5.0"
SCRIPT_URL="https://raw.githubusercontent.com/hugnanastore-eng/vps-manager/main/scripts"
CONFIG_DIR="/root/.vps-config"
CONFIG_FILE="$CONFIG_DIR/setup.conf"
VERSION_FILE="$CONFIG_DIR/version"
COMPONENTS_FILE="$CONFIG_DIR/components.json"
LOG_FILE="/var/log/vps-update.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ── Input Validation ──
validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]] || { err "Invalid domain: $1"; return 1; }
}
validate_ip() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { err "Invalid IP: $1"; return 1; }
}

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; echo "[WARN] $1" >> "$LOG_FILE"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; echo "[ERROR] $1" >> "$LOG_FILE"; }
skip() { echo -e "${CYAN}[SKIP]${NC} $1 — đã có sẵn"; }

# ============================================
# COMPONENT DETECTION ENGINE
# ============================================

detect_os() {
    if [ -f /etc/rocky-release ]; then
        OS="rocky"; PKG="dnf"
    elif [ -f /etc/almalinux-release ]; then
        OS="almalinux"; PKG="dnf"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"; PKG="yum"
    elif grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        OS="ubuntu"; PKG="apt"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then
        OS="debian"; PKG="apt"
    else
        OS="unknown"; PKG="unknown"
    fi
    echo "$OS"
}

detect_existing_panels() {
    local panels=""
    # HocVPS
    if [ -f /etc/hocvps/scripts.conf ] || command -v hocvps &>/dev/null; then
        panels="${panels}hocvps,"
    fi
    # aaPanel
    if [ -d /www/server/panel ] || command -v bt &>/dev/null; then
        panels="${panels}aapanel,"
    fi
    # CyberPanel
    if [ -d /usr/local/CyberCP ] || command -v cyberpanel &>/dev/null; then
        panels="${panels}cyberpanel,"
    fi
    # HestiaCP
    if [ -d /usr/local/hestia ] || command -v v-list-users &>/dev/null; then
        panels="${panels}hestiacp,"
    fi
    # CloudPanel
    if command -v clpctl &>/dev/null; then
        panels="${panels}cloudpanel,"
    fi
    # CWP
    if [ -d /usr/local/cwpsrv ]; then
        panels="${panels}cwp,"
    fi
    # VPS 1 Chạm (our script)
    if [ -f "$VERSION_FILE" ]; then
        panels="${panels}vps1cham,"
    fi
    echo "${panels%,}"  # remove trailing comma
}

check_component() {
    local name="$1"
    case "$name" in
        nginx)
            command -v nginx &>/dev/null && nginx -v 2>&1 | grep -qi nginx
            ;;
        php)
            command -v php &>/dev/null || command -v php-fpm &>/dev/null || ls /etc/php/*/fpm/ &>/dev/null 2>&1
            ;;
        mariadb)
            command -v mariadb &>/dev/null || command -v mysql &>/dev/null
            ;;
        redis)
            command -v redis-server &>/dev/null
            ;;
        fail2ban)
            command -v fail2ban-client &>/dev/null
            ;;
        certbot)
            command -v certbot &>/dev/null || [ -f /root/.acme.sh/acme.sh ]
            ;;
        wp-cli)
            command -v wp &>/dev/null
            ;;
        firewall)
            command -v ufw &>/dev/null || command -v firewall-cmd &>/dev/null
            ;;
        composer)
            command -v composer &>/dev/null
            ;;
        waf)
            [ -f /etc/nginx/conf.d/waf.conf ] || [ -f /etc/nginx/waf-rules.conf ]
            ;;
        vps-admin)
            command -v vps-admin &>/dev/null || [ -f /usr/local/bin/vps-admin.sh ]
            ;;
        backup-system)
            [ -f /usr/local/bin/backup_full.sh ] || crontab -l 2>/dev/null | grep -q backup
            ;;
        telegram-bot)
            [ -f "$CONFIG_DIR/telegram.conf" ] || grep -q "TELEGRAM_TOKEN" "$CONFIG_FILE" 2>/dev/null || grep -q "TG_TOKEN" "$CONFIG_FILE" 2>/dev/null || [ -f /usr/local/bin/tg_alert.sh ]
            ;;
        monitoring)
            [ -f /usr/local/bin/site_monitor.sh ] || crontab -l 2>/dev/null | grep -q monitor
            ;;
        security-headers)
            grep -rq "X-Frame-Options" /etc/nginx/ 2>/dev/null
            ;;
        opcache)
            php -m 2>/dev/null | grep -qi opcache
            ;;
        *)
            return 1
            ;;
    esac
}

get_component_version() {
    local name="$1"
    case "$name" in
        nginx) nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' ;;
        php) php -v 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' ;;
        mariadb) mariadb --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || mysql --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' ;;
        redis) redis-server --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' ;;
        wp-cli) wp --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' ;;
        *) echo "n/a" ;;
    esac
}

# ============================================
# SYSTEM AUDIT
# ============================================

run_audit() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   🔍  VPS SYSTEM AUDIT                    ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    local os=$(detect_os)
    log "OS: $os ($(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2))"
    log "RAM: $(free -h | awk '/Mem:/ {print $2}')"
    log "Disk: $(df -h / | awk 'NR==2{print $4}') free"
    log "CPU: $(nproc) cores"
    echo ""

    # Detect existing panels
    local panels=$(detect_existing_panels)
    if [ -n "$panels" ]; then
        echo -e "${YELLOW}📋 Panel/Script đã cài:${NC}"
        IFS=',' read -ra PANEL_LIST <<< "$panels"
        for p in "${PANEL_LIST[@]}"; do
            case "$p" in
                hocvps) echo -e "   → ${CYAN}HocVPS Script${NC}" ;;
                aapanel) echo -e "   → ${CYAN}aaPanel${NC}" ;;
                cyberpanel) echo -e "   → ${CYAN}CyberPanel${NC}" ;;
                hestiacp) echo -e "   → ${CYAN}HestiaCP${NC}" ;;
                cloudpanel) echo -e "   → ${CYAN}CloudPanel${NC}" ;;
                cwp) echo -e "   → ${CYAN}CWP${NC}" ;;
                vps1cham) echo -e "   → ${GREEN}VPS 1 Chạm v$(cat $VERSION_FILE 2>/dev/null)${NC}" ;;
            esac
        done
        echo ""
    fi

    # Check all components
    echo -e "${BOLD}📦 Component Status:${NC}"
    echo -e "┌─────────────────────┬──────────┬──────────────┐"
    printf "│ %-19s │ %-8s │ %-12s │\n" "Component" "Status" "Version"
    echo -e "├─────────────────────┼──────────┼──────────────┤"

    local components=("nginx" "php" "mariadb" "redis" "fail2ban" "certbot" "wp-cli" "firewall" "waf" "vps-admin" "backup-system" "telegram-bot" "monitoring" "security-headers" "opcache")
    local installed_count=0
    local missing_components=""

    for comp in "${components[@]}"; do
        if check_component "$comp"; then
            local ver=$(get_component_version "$comp")
            printf "│ %-19s │ ${GREEN}%-8s${NC} │ %-12s │\n" "$comp" "✓ OK" "${ver:-built-in}"
            ((installed_count++))
        else
            printf "│ %-19s │ ${RED}%-8s${NC} │ %-12s │\n" "$comp" "✗ Missing" "—"
            missing_components="${missing_components}${comp},"
        fi
    done

    echo -e "└─────────────────────┴──────────┴──────────────┘"
    echo ""
    log "Installed: $installed_count/${#components[@]} components"

    if [ -n "$missing_components" ]; then
        echo -e "${YELLOW}Missing: ${missing_components%,}${NC}"
    else
        echo -e "${GREEN}✅ All components installed!${NC}"
    fi

    # Check WordPress sites
    echo ""
    echo -e "${BOLD}🌐 WordPress Sites:${NC}"
    local sites_found=0
    for dir in /var/www/*/; do
        if [ -f "$dir/wp-config.php" ]; then
            local domain=$(basename "$dir")
            local wp_ver=$(grep "wp_version = " "$dir/wp-includes/version.php" 2>/dev/null | cut -d"'" -f2)
            echo -e "   → ${CYAN}$domain${NC} (WP $wp_ver)"
            ((sites_found++))
        fi
    done
    [ $sites_found -eq 0 ] && echo "   (none found)"

    echo ""

    # Return results
    AUDIT_OS="$os"
    AUDIT_PANELS="$panels"
    AUDIT_MISSING="$missing_components"
    AUDIT_INSTALLED="$installed_count"
}

# ============================================
# SMART INSTALL — only install missing
# ============================================

smart_install_component() {
    local comp="$1"
    local os="$2"

    if check_component "$comp"; then
        skip "$comp"
        return 0
    fi

    log "Installing $comp..."

    case "$comp" in
        nginx)
            if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
                apt-get install -y nginx
            else
                dnf install -y nginx
            fi
            systemctl enable nginx
            systemctl start nginx
            ;;
        php)
            if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
                apt-get install -y php8.1 php8.1-fpm php8.1-mysql php8.1-curl php8.1-xml php8.1-mbstring php8.1-zip php8.1-gd php8.1-intl php8.1-opcache php8.1-redis php8.1-imagick
            else
                dnf install -y php php-fpm php-mysqlnd php-curl php-xml php-mbstring php-zip php-gd php-intl php-opcache php-redis php-imagick
            fi
            ;;
        mariadb)
            if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
                apt-get install -y mariadb-server mariadb-client
            else
                dnf install -y mariadb-server mariadb
            fi
            systemctl enable mariadb
            systemctl start mariadb
            ;;
        redis)
            if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
                apt-get install -y redis-server
            else
                dnf install -y redis
            fi
            systemctl enable redis
            systemctl start redis
            ;;
        fail2ban)
            if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
                apt-get install -y fail2ban
            else
                dnf install -y fail2ban
            fi
            systemctl enable fail2ban
            systemctl start fail2ban
            ;;
        certbot)
            if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
                apt-get install -y certbot python3-certbot-nginx
            else
                dnf install -y certbot python3-certbot-nginx
            fi
            ;;
        wp-cli)
            curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
            chmod +x wp-cli.phar
            mv wp-cli.phar /usr/local/bin/wp
            ;;
        firewall)
            if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
                apt-get install -y ufw
                ufw --force enable
                ufw allow 22/tcp
                ufw allow 80/tcp
                ufw allow 443/tcp
            else
                systemctl enable firewalld
                systemctl start firewalld
                firewall-cmd --permanent --add-service=http
                firewall-cmd --permanent --add-service=https
                firewall-cmd --permanent --add-service=ssh
                firewall-cmd --reload
            fi
            ;;
        waf)
            install_waf_rules
            ;;
        vps-admin)
            install_admin_panel
            ;;
        backup-system)
            install_backup_system
            ;;
        monitoring)
            install_monitoring
            ;;
        security-headers)
            install_security_headers
            ;;
        opcache)
            configure_opcache
            ;;
    esac

    log "✓ $comp installed"
}

# ============================================
# MODULE INSTALLERS (standalone, safe to add)
# ============================================

install_waf_rules() {
    log "Setting up WAF rules..."
    cat > /etc/nginx/waf-rules.conf << 'WAFEOF'
# VPS 1 Chạm WAF Rules
# Block SQL injection
set $block_sql_injections 0;
if ($query_string ~ "union.*select.*\(") { set $block_sql_injections 1; }
if ($query_string ~ "concat.*\(") { set $block_sql_injections 1; }
if ($block_sql_injections = 1) { return 403; }

# Block file injections
set $block_file_injections 0;
if ($query_string ~ "[a-zA-Z0-9_]=http://") { set $block_file_injections 1; }
if ($query_string ~ "[a-zA-Z0-9_]=(\.\.//?)+") { set $block_file_injections 1; }
if ($block_file_injections = 1) { return 403; }

# Block common exploits
if ($query_string ~ "proc/self/environ") { return 403; }
if ($query_string ~ "mosConfig_[a-zA-Z_]{1,21}(=|\%3D)") { return 403; }
if ($query_string ~ "base64_(en|de)code\(.*\)") { return 403; }

# Block bad user agents
if ($http_user_agent ~* "nmap|nikto|wikto|sf|sqlmap|bsqlbf|w3af|acunetix|havij|appscan") { return 403; }
WAFEOF
    # Include in each server block (set/if directives require server context)
    # Remove old http-level include if present
    sed -i '/include.*waf-rules\.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
    # Add to each server block in conf.d
    for conf in /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue
        if ! grep -q "waf-rules.conf" "$conf" 2>/dev/null; then
            sed -i '/server_name/a \    include /etc/nginx/waf-rules.conf;' "$conf" 2>/dev/null || true
        fi
    done
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || warn "WAF rules need manual nginx config"
}

install_admin_panel() {
    log "Installing VPS Admin Panel..."
    curl -fsSL --retry 3 "$SCRIPT_URL/vps-admin.sh" -o /usr/local/bin/vps-admin.sh 2>/dev/null || {
        # Fallback: copy from local if available
        [ -f /root/vps-setup/vps-admin.sh ] && cp /root/vps-setup/vps-admin.sh /usr/local/bin/vps-admin.sh
    }
    chmod +x /usr/local/bin/vps-admin.sh
    ln -sf /usr/local/bin/vps-admin.sh /usr/local/bin/vps-admin

    # Install modules
    log "Installing admin modules..."
    mkdir -p /usr/local/bin/vps-modules
    local MODULES_URL="$SCRIPT_URL/modules"
    local modules=(
        "multi-ip.sh"
        "backup_split.sh"
        "wp_auto_update.sh"
        "resource_alert.sh"
        "disk_cleanup.sh"
        "ssh_key_manager.sh"
        "domain_health.sh"
        "wp_staging.sh"
        "simple_analytics.sh"
    )
    for mod in "${modules[@]}"; do
        curl -fsSL --retry 3 "$MODULES_URL/$mod" -o "/usr/local/bin/vps-modules/$mod" 2>/dev/null && \
            chmod +x "/usr/local/bin/vps-modules/$mod" && \
            log "  ✓ Module: $mod" || \
            warn "  ✗ Failed: $mod"
    done

    # Install language files (i18n)
    log "Installing language files..."
    mkdir -p /usr/local/bin/vps-modules/lang
    local LANG_URL="$SCRIPT_URL/lang"
    local langs=("en" "vi" "zh" "ja" "fr" "es" "pt")
    for lang in "${langs[@]}"; do
        curl -fsSL --retry 3 "$LANG_URL/${lang}.sh" -o "/usr/local/bin/vps-modules/lang/${lang}.sh" 2>/dev/null && \
            chmod +x "/usr/local/bin/vps-modules/lang/${lang}.sh" && \
            log "  ✓ Lang: ${lang}.sh" || \
            warn "  ✗ Failed: ${lang}.sh"
    done

    log "Admin panel + ${#modules[@]} modules + ${#langs[@]} languages installed. Run: vps-admin"
}

install_backup_system() {
    log "Setting up backup system..."
    mkdir -p /backup/{daily,weekly}

    cat > /usr/local/bin/backup_full.sh << 'BAKEOF'
#!/bin/bash
BACKUP_DIR="/backup/daily"
DATE=$(date +%Y%m%d_%H%M)
mkdir -p "$BACKUP_DIR"

# Backup all databases
for db in $(mysql -e "SHOW DATABASES" -N 2>/dev/null | grep -vE "^(information_schema|performance_schema|mysql|sys)$"); do
    mysqldump --single-transaction --routines --triggers "$db" 2>/dev/null | gzip > "$BACKUP_DIR/${db}_${DATE}.sql.gz"
done

# Backup WordPress files
for dir in /var/www/*/; do
    [ -f "$dir/wp-config.php" ] || continue
    domain=$(basename "$dir")
    tar czf "$BACKUP_DIR/${domain}_files_${DATE}.tar.gz" -C /var/www "$domain" 2>/dev/null
done

# Backup configs
tar czf "$BACKUP_DIR/configs_${DATE}.tar.gz" /etc/nginx/conf.d/ /etc/php/ 2>/dev/null

# Clean old (7 days)
find "$BACKUP_DIR" -name "*.gz" -mtime +7 -delete

echo "[$(date)] Backup completed: $BACKUP_DIR"
BAKEOF

    chmod +x /usr/local/bin/backup_full.sh
    chmod 600 /root/.vps-config/db-credentials.txt 2>/dev/null

    # Add cron if not exists
    if ! crontab -l 2>/dev/null | grep -q backup_full; then
        (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup_full.sh >> /var/log/backup.log 2>&1") | crontab -
    fi
}

install_monitoring() {
    log "Setting up site monitoring..."

    cat > /usr/local/bin/site_monitor.sh << 'MONEOF'
#!/bin/bash
CONFIG="/root/.vps-config/setup.conf"
[ -f "$CONFIG" ] && source "$CONFIG"

for dir in /var/www/*/; do
    [ -f "$dir/wp-config.php" ] || continue
    domain=$(basename "$dir")
    status=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 10 "https://$domain" 2>/dev/null || echo "000")

    if [ "$status" != "200" ] && [ "$status" != "301" ] && [ "$status" != "302" ]; then
        msg="⚠️ Site DOWN: $domain (HTTP $status)"
        echo "[$(date)] $msg"
        # Send Telegram alert if configured
        if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=$msg" >/dev/null 2>&1
        fi
    fi
done
MONEOF

    chmod +x /usr/local/bin/site_monitor.sh

    if ! crontab -l 2>/dev/null | grep -q site_monitor; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/site_monitor.sh >> /var/log/monitor.log 2>&1") | crontab -
    fi
}

install_security_headers() {
    log "Setting up security headers..."

    cat > /etc/nginx/conf.d/security-headers.conf << 'SECEOF'
# VPS 1 Chạm Security Headers
# NOTE: These headers are added globally. Location blocks must be in server context.
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
SECEOF

    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || warn "Security headers need manual review"
}

configure_opcache() {
    log "Configuring OPcache..."
    local opcache_ini=$(find /etc/php/ -name "10-opcache.ini" 2>/dev/null | head -1)
    [ -z "$opcache_ini" ] && opcache_ini=$(find /etc/php.d/ -name "10-opcache.ini" 2>/dev/null | head -1)

    if [ -n "$opcache_ini" ]; then
        cat > "$opcache_ini" << 'OPCEOF'
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.fast_shutdown=1
OPCEOF
        systemctl restart php*-fpm 2>/dev/null || true
    else
        warn "OPcache ini not found, skip config"
    fi
}

# ============================================
# WORDPRESS MALWARE SCANNER (Deep Scan)
# ============================================

run_malware_scan() {
    echo ""
    echo -e "${RED}${BOLD}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║   🛡️  DEEP WORDPRESS MALWARE SCANNER          ║${NC}"
    echo -e "${RED}${BOLD}║   Quét 12 bước — phát hiện mọi loại mã độc    ║${NC}"
    echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    local infected=0
    local checked=0
    local issues=""
    local scan_log="/var/log/malware-scan-$(date +%Y%m%d_%H%M).log"
    touch "$scan_log" 2>/dev/null

    scan_log_entry() { echo "[$(date '+%H:%M:%S')] $1" >> "$scan_log"; }

    # ── 1. WPCode / Code Snippets DB check ──
    echo -e "${BOLD}[1/12] Scanning WPCode/Snippet plugins...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        ((checked++))

        if [ -d "$dir/wp-content/plugins/insert-headers-and-footers" ]; then
            if command -v wp &>/dev/null; then
                local prefix=$(wp db prefix --path="$dir" --allow-root 2>/dev/null)
                local suspicious=$(wp db query "SELECT ID, post_title FROM ${prefix}posts WHERE post_type='wpcode' AND (post_content LIKE '%base64_decode%' OR post_content LIKE '%eval(%' OR post_content LIKE '%\$_POST%' OR post_content LIKE '%\$_REQUEST%')" --path="$dir" --allow-root 2>/dev/null | tail -n +2)
                if [ -n "$suspicious" ]; then
                    echo -e "   ${RED}🔴 [$domain] MALWARE in WPCode snippet!${NC}"
                    echo "$suspicious" | head -5
                    ((infected++)); issues="${issues}[$domain] WPCode malware\n"
                    scan_log_entry "INFECTED: $domain - WPCode snippet"
                else
                    echo -e "   ${GREEN}✓${NC} [$domain] WPCode clean"
                fi
            fi
        fi
    done
    [ $checked -eq 0 ] && echo "   (no WordPress sites found)"

    # ── 2. Theme file injection ──
    echo -e "\n${BOLD}[2/12] Scanning theme files...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        local theme_infected=0

        for tfile in "$dir"/wp-content/themes/*/header.php "$dir"/wp-content/themes/*/footer.php "$dir"/wp-content/themes/*/functions.php "$dir"/wp-content/themes/*/index.php; do
            [ -f "$tfile" ] || continue
            if grep -qE 'eval\s*\(\s*(base64_decode|gzinflate|str_rot13|gzuncompress|rawurldecode)' "$tfile" 2>/dev/null; then
                local tname=$(basename $(dirname "$tfile"))/$(basename "$tfile")
                echo -e "   ${RED}🔴 [$domain] Injection: $tname${NC}"
                ((infected++)); ((theme_infected++))
                issues="${issues}[$domain] Theme: $tname\n"
            fi
        done
        [ $theme_infected -eq 0 ] && echo -e "   ${GREEN}✓${NC} [$domain] Theme files clean"
    done

    # ── 3. PHP files in uploads (shell backdoors) ──
    echo -e "\n${BOLD}[3/12] Scanning uploads for PHP backdoors...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        local uploads="$dir/wp-content/uploads"
        [ -d "$uploads" ] || continue

        local php_files=$(find "$uploads" -name '*.php' -o -name '*.phtml' -o -name '*.php5' -o -name '*.phar' 2>/dev/null | grep -v 'index.php')
        if [ -n "$php_files" ]; then
            echo -e "   ${RED}🔴 [$domain] PHP files in uploads:${NC}"
            echo "$php_files" | head -10 | while read f; do
                echo -e "      ${YELLOW}→ $(basename "$f")${NC}"
                grep -qE 'eval|base64_decode|system\(|exec\(|passthru|shell_exec|proc_open' "$f" 2>/dev/null && \
                    echo -e "      ${RED}  ⚠ Contains shell functions!${NC}"
            done
            ((infected++)); issues="${issues}[$domain] PHP in uploads\n"
        else
            echo -e "   ${GREEN}✓${NC} [$domain] Uploads clean"
        fi
    done

    # ── 4. Known backdoor signatures ──
    echo -e "\n${BOLD}[4/12] Scanning for known backdoor signatures...${NC}"
    local backdoor_patterns='(c99shell|r57shell|WSO |FilesMan|b374k|adminer\.php|phpspy|webshell|0x6578|Hacked By|mini shell)'
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        local found=$(grep -rlE "$backdoor_patterns" "$dir/wp-content/" 2>/dev/null | head -10)
        if [ -n "$found" ]; then
            echo -e "   ${RED}🔴 [$domain] Known backdoor found:${NC}"
            echo "$found" | while read f; do echo -e "      ${RED}→ $f${NC}"; done
            ((infected++)); issues="${issues}[$domain] Known backdoor\n"
        else
            echo -e "   ${GREEN}✓${NC} [$domain] No known backdoors"
        fi
    done

    # ── 5. Hidden PHP files (dot-prefixed) ──
    echo -e "\n${BOLD}[5/12] Scanning for hidden PHP files...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        local hidden=$(find "$dir" -name '.*.php' -o -name '..*.php' -o -name '.thumb.php' -o -name '.cache.php' -o -name '.log.php' 2>/dev/null | head -10)
        if [ -n "$hidden" ]; then
            echo -e "   ${RED}🔴 [$domain] Hidden PHP files:${NC}"
            echo "$hidden" | while read f; do echo -e "      ${RED}→ $f${NC}"; done
            ((infected++)); issues="${issues}[$domain] Hidden PHP files\n"
        else
            echo -e "   ${GREEN}✓${NC} [$domain] No hidden PHP"
        fi
    done

    # ── 6. Suspicious .htaccess ──
    echo -e "\n${BOLD}[6/12] Scanning .htaccess files...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        local bad_htaccess=$(find "$dir" -name '.htaccess' -exec grep -lE 'RewriteCond.*HTTP_REFERER|eval|base64_decode|auto_prepend_file|php_value auto' {} \; 2>/dev/null)
        if [ -n "$bad_htaccess" ]; then
            echo -e "   ${RED}🔴 [$domain] Suspicious .htaccess:${NC}"
            echo "$bad_htaccess" | while read f; do echo -e "      ${YELLOW}→ $f${NC}"; done
            ((infected++)); issues="${issues}[$domain] .htaccess injected\n"
        else
            echo -e "   ${GREEN}✓${NC} [$domain] .htaccess clean"
        fi
    done

    # ── 7. wp-config.php injection ──
    echo -e "\n${BOLD}[7/12] Scanning wp-config.php...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        if grep -qE 'eval\(|base64_decode|@include|@require.*\$|error_reporting\(0\)' "$dir/wp-config.php" 2>/dev/null; then
            echo -e "   ${RED}🔴 [$domain] wp-config.php injected!${NC}"
            grep -n 'eval\|base64_decode\|@include\|@require' "$dir/wp-config.php" | head -5
            ((infected++)); issues="${issues}[$domain] wp-config injected\n"
        else
            echo -e "   ${GREEN}✓${NC} [$domain] wp-config.php clean"
        fi
    done

    # ── 8. Database injection (wp_options) ──
    echo -e "\n${BOLD}[8/12] Scanning database wp_options...${NC}"
    if command -v wp &>/dev/null; then
        for dir in /var/www/*/; do
            [ -f "$dir/wp-config.php" ] || continue
            local domain=$(basename "$dir")
            local prefix=$(wp db prefix --path="$dir" --allow-root 2>/dev/null)
            local db_inject=$(wp db query "SELECT option_name FROM ${prefix}options WHERE option_value LIKE '%eval(%' OR option_value LIKE '%base64_decode(%' OR option_value LIKE '%<script%src=_http%' LIMIT 5" --path="$dir" --allow-root 2>/dev/null | tail -n +2)
            if [ -n "$db_inject" ]; then
                echo -e "   ${RED}🔴 [$domain] Injected DB options:${NC}"
                echo "$db_inject" | while read o; do echo -e "      ${YELLOW}→ $o${NC}"; done
                ((infected++)); issues="${issues}[$domain] DB injection\n"
            else
                echo -e "   ${GREEN}✓${NC} [$domain] Database clean"
            fi
        done
    else
        echo -e "   ${YELLOW}⚠ WP-CLI not found, skipping DB scan${NC}"
    fi

    # ── 9. Recently modified core files ──
    echo -e "\n${BOLD}[9/12] Checking recently modified core files (3 days)...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        local modified=$(find "$dir/wp-includes" "$dir/wp-admin" -name '*.php' -mtime -3 2>/dev/null | head -10)
        if [ -n "$modified" ]; then
            echo -e "   ${YELLOW}⚠ [$domain] Recently modified core files:${NC}"
            echo "$modified" | while read f; do echo -e "      → $(echo $f | sed "s|$dir||")"; done
            issues="${issues}[$domain] Modified core files (review needed)\n"
        else
            echo -e "   ${GREEN}✓${NC} [$domain] Core files untouched"
        fi
    done

    # ── 10. File permission anomalies ──
    echo -e "\n${BOLD}[10/12] Checking file permissions...${NC}"
    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")
        local world_writable=$(find "$dir" -perm -0002 -type f -name '*.php' 2>/dev/null | wc -l)
        local perm_777=$(find "$dir" -perm 0777 -type f 2>/dev/null | wc -l)
        if [ "$world_writable" -gt 0 ] || [ "$perm_777" -gt 0 ]; then
            echo -e "   ${YELLOW}⚠ [$domain] ${world_writable} world-writable, ${perm_777} chmod 777${NC}"
            issues="${issues}[$domain] Permission issues ($perm_777 files)\n"
        else
            echo -e "   ${GREEN}✓${NC} [$domain] Permissions OK"
        fi
    done

    # ── 11. Crontab scan ──
    echo -e "\n${BOLD}[11/12] Scanning crontab for suspicious entries...${NC}"
    local cron_bad=$(crontab -l 2>/dev/null | grep -iE 'wget.*-O-.*\|.*sh|curl.*\|.*sh|/tmp/.*\.sh|base64|python.*-c' | grep -v 'qltro\|backup\|monitor\|certbot\|acme')
    if [ -n "$cron_bad" ]; then
        echo -e "   ${RED}🔴 Suspicious cron entries:${NC}"
        echo "$cron_bad" | while read c; do echo -e "      ${RED}→ $c${NC}"; done
        ((infected++)); issues="${issues}Suspicious cron entries\n"
    else
        echo -e "   ${GREEN}✓${NC} Crontab clean"
    fi
    # Check /etc/cron.d/ for injected crons
    local sys_cron=$(find /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ -type f -newer /var/log/lastlog 2>/dev/null | head -5)
    [ -n "$sys_cron" ] && echo -e "   ${YELLOW}⚠ New system cron files: $sys_cron${NC}"

    # ── 12. WordPress admin users ──
    echo -e "\n${BOLD}[12/12] Scanning WordPress admin users...${NC}"
    if command -v wp &>/dev/null; then
        for dir in /var/www/*/; do
            [ -f "$dir/wp-config.php" ] || continue
            local domain=$(basename "$dir")
            local admins=$(wp user list --role=administrator --fields=user_login,user_email,user_registered --format=table --path="$dir" --allow-root 2>/dev/null)
            if [ -n "$admins" ]; then
                echo -e "   ${CYAN}[$domain] Admins:${NC}"
                echo "$admins" | while read line; do echo "      $line"; done
            fi
        done
    else
        echo -e "   ${YELLOW}⚠ WP-CLI not found${NC}"
    fi

    # ═══ SUMMARY ═══
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════${NC}"
    if [ $infected -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✅ CLEAN — No malware detected across $checked sites!${NC}"
    else
        echo -e "${RED}${BOLD}🚨 INFECTED — $infected issue(s) found!${NC}"
        echo ""
        echo -e "${RED}Issues:${NC}"
        echo -e "$issues"
        echo -e "${YELLOW}Recommended:${NC}"
        echo "  1. Run with --auto-clean to auto-remove obvious threats"
        echo "  2. Change all WP admin passwords"
        echo "  3. Update all plugins and themes"
        echo "  4. Check server access logs for attacker IP"
        echo "  5. Install Wordfence for ongoing protection"
        echo ""
        if [ "${1:-}" = "--auto-clean" ]; then
            echo -e "${YELLOW}Running auto-clean...${NC}"
            auto_clean_malware
        else
            echo -e "  ${CYAN}vps-update malware-scan --auto-clean${NC} to auto-fix"
        fi
    fi
    echo -e "${BOLD}══════════════════════════════════════════════${NC}"
    echo -e "Full log: ${CYAN}$scan_log${NC}"
    echo ""
}

auto_clean_malware() {
    log "Auto-cleaning malware..."

    for dir in /var/www/*/; do
        [ -f "$dir/wp-config.php" ] || continue
        local domain=$(basename "$dir")

        # Remove PHP in uploads
        local removed=$(find "$dir/wp-content/uploads" -name '*.php' -o -name '*.phtml' -o -name '*.php5' -o -name '*.phar' 2>/dev/null | grep -v 'index.php' | wc -l)
        find "$dir/wp-content/uploads" \( -name '*.php' -o -name '*.phtml' -o -name '*.php5' -o -name '*.phar' \) ! -name 'index.php' -delete 2>/dev/null
        [ "$removed" -gt 0 ] && log "✓ Removed $removed PHP files from uploads ($domain)"

        # Remove hidden PHP files
        find "$dir" -name '.*.php' -delete 2>/dev/null

        # Fix permissions
        find "$dir" -perm 0777 -type f -exec chmod 644 {} \; 2>/dev/null
        find "$dir" -perm -0002 -type f -name '*.php' -exec chmod 644 {} \; 2>/dev/null
        log "✓ Fixed permissions for $domain"

        # Trash WPCode malicious snippets
        if command -v wp &>/dev/null; then
            local prefix=$(wp db prefix --path="$dir" --allow-root 2>/dev/null)
            wp db query "UPDATE ${prefix}posts SET post_status='trash' WHERE post_type='wpcode' AND (post_content LIKE '%base64_decode%' OR post_content LIKE '%eval(%')" --path="$dir" --allow-root 2>/dev/null
            log "✓ Trashed malicious WPCode snippets ($domain)"
        fi
    done

    log "✅ Auto-clean complete. Run scan again to verify."
}

# ============================================
# FIREWALL & SECURITY HARDENING
# ============================================

harden_firewall() {
    echo ""
    echo -e "${RED}${BOLD}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║   🔥 FIREWALL & SECURITY HARDENING            ║${NC}"
    echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    local os=$(detect_os)

    # ── 1. Kernel hardening (SYN flood, IP spoofing) ──
    echo -e "${BOLD}[1/7] Kernel hardening (SYN flood, IP spoofing)...${NC}"
    cat > /etc/sysctl.d/99-vps-security.conf << 'SYSEOF'
# VPS 1 Chạm - Kernel Security Hardening
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# TCP optimization
net.core.somaxconn = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
SYSEOF
    sysctl --system > /dev/null 2>&1
    echo -e "   ${GREEN}✓${NC} Kernel hardened"

    # ── 2. Firewall rules ──
    echo -e "${BOLD}[2/7] Configuring firewall...${NC}"
    if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
        apt-get install -y ufw > /dev/null 2>&1
        # Only reset if ufw has no custom rules (fresh setup)
        if ! ufw status 2>/dev/null | grep -q "ALLOW\|DENY"; then
            ufw --force reset > /dev/null 2>&1
        fi
        ufw default deny incoming > /dev/null 2>&1
        ufw default allow outgoing > /dev/null 2>&1
        ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
        ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
        ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1
        # Rate limit SSH
        ufw limit 22/tcp > /dev/null 2>&1
        ufw --force enable > /dev/null 2>&1
        echo -e "   ${GREEN}✓${NC} UFW configured (SSH rate-limited, HTTP/HTTPS open)"
    else
        # CentOS/Rocky - firewalld
        systemctl enable firewalld > /dev/null 2>&1
        systemctl start firewalld > /dev/null 2>&1
        firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
        firewall-cmd --permanent --add-service=http > /dev/null 2>&1
        firewall-cmd --permanent --add-service=https > /dev/null 2>&1
        # Rate limit SSH via rich rule
        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" service name="ssh" accept limit value="5/m"' > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1
        echo -e "   ${GREEN}✓${NC} Firewalld configured (SSH rate-limited)"
    fi

    # ── 3. fail2ban advanced config ──
    echo -e "${BOLD}[3/7] Configuring fail2ban jails...${NC}"
    if ! command -v fail2ban-client &>/dev/null; then
        if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
            apt-get install -y fail2ban > /dev/null 2>&1
        else
            dnf install -y fail2ban > /dev/null 2>&1
        fi
    fi

    cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd
banaction = %(banaction_allports)s

[sshd]
enabled = true
port = ssh
maxretry = 5
bantime = 3600

[nginx-http-auth]
enabled = true
port = http,https
maxretry = 5
bantime = 3600

[nginx-botsearch]
enabled = true
port = http,https
maxretry = 3
bantime = 86400

[wordpress-login]
enabled = true
port = http,https
filter = wordpress-login
logpath = /var/log/nginx/access.log
maxretry = 5
bantime = 3600
findtime = 300

[xmlrpc]
enabled = true
port = http,https
filter = xmlrpc
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
F2BEOF

    # WordPress login filter
    cat > /etc/fail2ban/filter.d/wordpress-login.conf << 'WPEOF'
[Definition]
failregex = ^<HOST> .* "POST /wp-login.php
            ^<HOST> .* "POST /wp-admin
ignoreregex =
WPEOF

    # XMLRPC filter
    cat > /etc/fail2ban/filter.d/xmlrpc.conf << 'XMLEOF'
[Definition]
failregex = ^<HOST> .* "POST /xmlrpc.php
ignoreregex =
XMLEOF

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban > /dev/null 2>&1
    echo -e "   ${GREEN}✓${NC} fail2ban: SSH, WP-login, XMLRPC, bot-search jails active"

    # ── 4. SSH hardening (keep password login) ──
    echo -e "${BOLD}[4/7] SSH hardening (password login kept)...${NC}"
    local sshd_conf="/etc/ssh/sshd_config"
    cp "$sshd_conf" "${sshd_conf}.bak" 2>/dev/null

    # Keep password auth enabled but harden everything else
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$sshd_conf"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_conf"
    sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 5/' "$sshd_conf"
    sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 60/' "$sshd_conf"
    sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 300/' "$sshd_conf"
    sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 2/' "$sshd_conf"
    # Disable empty passwords
    sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshd_conf"
    # Disable X11 forwarding
    sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$sshd_conf"

    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo -e "   ${GREEN}✓${NC} SSH hardened (password login: ${CYAN}enabled${NC})"

    # ── 5. Nginx DDoS & exploit protection ──
    echo -e "${BOLD}[5/7] Nginx DDoS & exploit protection...${NC}"
    cat > /etc/nginx/conf.d/ddos-protection.conf << 'DDOSEOF'
# VPS 1 Chạm - DDoS & Exploit Protection
# Connection limiting per IP
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;
limit_req_zone $binary_remote_addr zone=req_limit:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=wp_login:10m rate=1r/s;

# Note: limit_conn should be applied per-server block, not globally
# limit_conn conn_limit 100;  # Apply this in individual server blocks

# Block common exploit URIs
map $request_uri $block_uri {
    default 0;
    ~*wp-config\.php\.bak 1;
    ~*\.sql$ 1;
    ~*\.tar\.gz$ 1;
    ~*\.zip$ 1;
    ~*phpinfo 1;
    ~*phpmyadmin 1;
    ~*adminer 1;
    ~*/\.env 1;
    ~*/\.git 1;
}
DDOSEOF

    # Test and reload
    if nginx -t 2>/dev/null; then
        nginx -s reload 2>/dev/null
        echo -e "   ${GREEN}✓${NC} Nginx DDoS protection + exploit blocking active"
    else
        rm -f /etc/nginx/conf.d/ddos-protection.conf
        warn "Nginx config test failed, DDoS protection skipped"
    fi

    # ── 6. Auto security updates ──
    echo -e "${BOLD}[6/7] Auto security updates...${NC}"
    if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
        apt-get install -y unattended-upgrades > /dev/null 2>&1
        dpkg-reconfigure -plow unattended-upgrades > /dev/null 2>&1
        echo -e "   ${GREEN}✓${NC} Unattended-upgrades enabled"
    else
        # CentOS/Rocky - dnf-automatic
        dnf install -y dnf-automatic > /dev/null 2>&1
        sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null
        systemctl enable dnf-automatic.timer > /dev/null 2>&1
        systemctl start dnf-automatic.timer > /dev/null 2>&1
        echo -e "   ${GREEN}✓${NC} DNF automatic security updates enabled"
    fi

    # ── 7. Root password prompt ──
    echo -e "${BOLD}[7/7] Root password management...${NC}"
    echo ""
    echo -e "   ${YELLOW}⚠ KHUYẾN NGHỊ: Đổi mật khẩu root ngay!${NC}"
    echo -e "   Mật khẩu mạnh: >= 16 ký tự, chữ hoa + thường + số + ký tự đặc biệt"
    echo ""
    if [ -e /dev/tty ]; then read -p "   Đổi mật khẩu root ngay? (y/N): " CHANGE_PASS < /dev/tty; else CHANGE_PASS="n"; fi
    if [ "$CHANGE_PASS" = "y" ] || [ "$CHANGE_PASS" = "Y" ]; then
        if [ -t 0 ]; then
            # Interactive terminal — use passwd
            passwd root
        else
            # Piped mode — generate and set password
            local NEW_ROOT_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
            echo "root:${NEW_ROOT_PASS}" | chpasswd
            echo -e "   ${YELLOW}⚠ MẬT KHẨU MỚI: ${CYAN}${NEW_ROOT_PASS}${NC}"
            echo -e "   ${RED}⚠ LƯU LẠI NGAY! Mất mật khẩu = mất VPS!${NC}"
        fi
        echo -e "   ${GREEN}✓ Mật khẩu đã đổi!${NC}"
    else
        echo -e "   ${CYAN}→ Bỏ qua. Chạy 'passwd root' khi cần.${NC}"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✅ FIREWALL HARDENING COMPLETE${NC}"
    echo -e "  • Kernel: SYN flood + IP spoofing protection"
    echo -e "  • Firewall: SSH rate-limited, HTTP/HTTPS open"
    echo -e "  • fail2ban: 5 jails (SSH, WP-login, XMLRPC, bots, auth)"
    echo -e "  • SSH: Hardened, password login kept"
    echo -e "  • Nginx: DDoS limiting + exploit URI blocking"
    echo -e "  • Auto security updates enabled"
    echo ""
}

# ============================================
# UPDATE ENGINE
# ============================================

check_update() {
    log "Checking for updates..."

    local current_version=$(cat "$VERSION_FILE" 2>/dev/null || echo "0.0.0")
    local remote_version=$(curl -sfL --max-time 5 "$SCRIPT_URL/version.txt" 2>/dev/null || echo "$VERSION")

    echo -e "${BOLD}Current version:${NC} $current_version"
    echo -e "${BOLD}Latest version:${NC}  $remote_version"

    if [ "$current_version" = "$remote_version" ]; then
        echo -e "${GREEN}✅ Already up to date!${NC}"
        return 0
    else
        echo -e "${YELLOW}⬆️ Update available: $current_version → $remote_version${NC}"
        return 1
    fi
}

do_update() {
    log "Starting update..."

    # Fetch REMOTE version (not local $VERSION which may be stale)
    local remote_ver
    remote_ver=$(curl -sfL --max-time 5 "$SCRIPT_URL/version.txt" 2>/dev/null)
    if [ -z "$remote_ver" ]; then
        remote_ver="$VERSION"
        log "⚠ Could not fetch remote version, using local: $remote_ver"
    fi

    # Backup current scripts
    mkdir -p /root/.vps-config/backup
    cp /usr/local/bin/vps-admin.sh /root/.vps-config/backup/vps-admin.sh.bak 2>/dev/null
    cp /usr/local/bin/backup_full.sh /root/.vps-config/backup/backup_full.sh.bak 2>/dev/null

    # Download latest scripts
    log "Downloading latest scripts..."
    curl -fsSL --retry 3 "$SCRIPT_URL/vps-setup.sh" -o /tmp/vps-setup-new.sh 2>/dev/null
    curl -fsSL --retry 3 "$SCRIPT_URL/vps-admin.sh" -o /tmp/vps-admin-new.sh 2>/dev/null
    curl -fsSL --retry 3 "$SCRIPT_URL/install.sh"   -o /tmp/vps-install-new.sh 2>/dev/null

    # Download all modules
    mkdir -p /usr/local/bin/vps-modules
    local _modules=("multi-ip" "backup_split" "wp_auto_update" "resource_alert" "disk_cleanup" "ssh_key_manager" "domain_health" "wp_staging" "simple_analytics")
    for _mod in "${_modules[@]}"; do
        curl -fsSL --retry 3 "$SCRIPT_URL/modules/${_mod}.sh" -o "/tmp/${_mod}-new.sh" 2>/dev/null
    done

    # Update admin panel
    if [ -f /tmp/vps-admin-new.sh ]; then
        mv /tmp/vps-admin-new.sh /usr/local/bin/vps-admin.sh
        chmod +x /usr/local/bin/vps-admin.sh
        ln -sf /usr/local/bin/vps-admin.sh /usr/local/bin/vps-admin
        log "✓ Admin panel updated"
    fi

    # Self-update install.sh (so next update uses new VERSION)
    if [ -f /tmp/vps-install-new.sh ]; then
        mv /tmp/vps-install-new.sh /usr/local/bin/vps-update.sh
        chmod +x /usr/local/bin/vps-update.sh
        ln -sf /usr/local/bin/vps-update.sh /usr/local/bin/vps-update
        log "✓ Installer updated"
    fi

    # Update all modules
    local _mod_updated=0
    for _mod in "${_modules[@]}"; do
        if [ -f "/tmp/${_mod}-new.sh" ]; then
            mv "/tmp/${_mod}-new.sh" "/usr/local/bin/vps-modules/${_mod}.sh"
            chmod +x "/usr/local/bin/vps-modules/${_mod}.sh"
            ((_mod_updated++))
        fi
    done
    [ $_mod_updated -gt 0 ] && log "✓ ${_mod_updated} modules updated"

    # Download and install language files
    log "Updating language files..."
    mkdir -p /usr/local/bin/vps-modules/lang
    local _langs=("en" "vi" "zh" "ja" "fr" "es" "pt")
    local _lang_updated=0
    for _lang in "${_langs[@]}"; do
        curl -fsSL --retry 3 "$SCRIPT_URL/lang/${_lang}.sh" -o "/tmp/lang-${_lang}-new.sh" 2>/dev/null
        if [ -f "/tmp/lang-${_lang}-new.sh" ] && [ -s "/tmp/lang-${_lang}-new.sh" ]; then
            mv "/tmp/lang-${_lang}-new.sh" "/usr/local/bin/vps-modules/lang/${_lang}.sh"
            chmod +x "/usr/local/bin/vps-modules/lang/${_lang}.sh"
            ((_lang_updated++))
        fi
    done
    [ $_lang_updated -gt 0 ] && log "✓ ${_lang_updated} language files updated"

    # Write REMOTE version (not stale local $VERSION)
    echo "$remote_ver" > "$VERSION_FILE"
    # Also update local variable so subsequent calls show correct version
    VERSION="$remote_ver"

    # Run audit to find missing components
    run_audit

    # Install missing
    if [ -n "$AUDIT_MISSING" ]; then
        echo ""
        echo -e "${BOLD}Installing missing components...${NC}"
        IFS=',' read -ra MISSING <<< "$AUDIT_MISSING"
        for comp in "${MISSING[@]}"; do
            [ -z "$comp" ] && continue
            smart_install_component "$comp" "$AUDIT_OS"
        done
    fi

    # Save component state
    save_component_state

    # Post-update health check
    log "Running post-update health check..."
    local _hc_ok=0 _hc_fail=0

    # Check critical services
    for _svc in nginx php-fpm mariadb; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then
            ((_hc_ok++))
        else
            # Try to restart
            systemctl restart "$_svc" 2>/dev/null
            sleep 2
            if systemctl is-active --quiet "$_svc" 2>/dev/null; then
                log "⚠ ${_svc} was down, restarted OK"
                ((_hc_ok++))
            else
                log "✗ ${_svc} FAILED to restart!"
                ((_hc_fail++))
            fi
        fi
    done

    # Check nginx config syntax
    if nginx -t 2>/dev/null; then
        ((_hc_ok++))
    else
        log "✗ nginx config syntax error!"
        ((_hc_fail++))
    fi

    # Check sites return HTTP 200
    local _sites_ok=0 _sites_total=0
    for _conf in /etc/nginx/conf.d/*.conf; do
        [ -f "$_conf" ] || continue
        local _sn=$(grep -m1 'server_name' "$_conf" 2>/dev/null | sed 's/server_name//;s/;//' | awk '{print $1}')
        [ -z "$_sn" ] || [[ "$_sn" == "staging."* ]] && continue
        ((_sites_total++))
        local _http_code=$(curl -so /dev/null -w "%{http_code}" --max-time 5 "http://localhost" -H "Host: $_sn" 2>/dev/null)
        if [[ "$_http_code" =~ ^(200|301|302|304)$ ]]; then
            ((_sites_ok++))
        fi
    done

    if [ $_hc_fail -eq 0 ]; then
        log "✓ Health check passed (${_hc_ok} services OK, ${_sites_ok}/${_sites_total} sites responding)"
    else
        log "⚠ Health check: ${_hc_fail} service(s) have issues!"
    fi

    # Anonymous install/update counter (non-blocking, ignore errors)
    curl -s --max-time 3 "https://qltro.com/api/vps-ping?v=${remote_ver}&a=update" >/dev/null 2>&1 &

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ UPDATE COMPLETE!                             ║${NC}"
    echo -e "${GREEN}║   Version: ${remote_ver}  (${_mod_updated} modules updated)       ║${NC}"
    if [ $_hc_fail -eq 0 ]; then
        echo -e "${GREEN}║   Health: ✓ All services OK                       ║${NC}"
    else
        echo -e "${YELLOW}║   Health: ⚠ ${_hc_fail} issue(s) — check above         ║${NC}"
    fi
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

save_component_state() {
    mkdir -p "$CONFIG_DIR"
    local components=("nginx" "php" "mariadb" "redis" "fail2ban" "certbot" "wp-cli" "firewall" "waf" "vps-admin" "backup-system" "monitoring" "security-headers" "opcache")

    echo "{" > "$COMPONENTS_FILE"
    local _save_ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "$VERSION")
    echo "  \"version\": \"$_save_ver\"," >> "$COMPONENTS_FILE"
    echo "  \"updated\": \"$(date -Iseconds)\"," >> "$COMPONENTS_FILE"
    echo "  \"os\": \"$(detect_os)\"," >> "$COMPONENTS_FILE"
    echo "  \"panels\": \"$(detect_existing_panels)\"," >> "$COMPONENTS_FILE"
    echo "  \"components\": {" >> "$COMPONENTS_FILE"

    local first=true
    for comp in "${components[@]}"; do
        [ "$first" = true ] && first=false || echo "," >> "$COMPONENTS_FILE"
        if check_component "$comp"; then
            local ver=$(get_component_version "$comp" 2>/dev/null)
            local safe_ver=$(echo "${ver:-true}" | tr -d '"\\')
            printf "    \"%s\": {\"installed\": true, \"version\": \"%s\"}" "$comp" "$safe_ver" >> "$COMPONENTS_FILE"
        else
            printf "    \"%s\": {\"installed\": false}" "$comp" >> "$COMPONENTS_FILE"
        fi
    done

    echo "" >> "$COMPONENTS_FILE"
    echo "  }" >> "$COMPONENTS_FILE"
    echo "}" >> "$COMPONENTS_FILE"
}

# ============================================
# MAIN ENTRY POINT
# ============================================

show_banner() {
    local _disp_ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "$VERSION")
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                               ║${NC}"
    echo -e "${BLUE}║   ${BOLD}VPS 1 Chạm — Smart Installer v${_disp_ver}${NC}${BLUE}       ║${NC}"
    echo -e "${BLUE}║   https://qltro.com/vps                       ║${NC}"
    echo -e "${BLUE}║                                               ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════╝${NC}"
    echo ""
}

show_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install       Full install (VPS trắng, cài tất cả)"
    echo "  smart         Smart install (detect & skip existing, add missing)"
    echo "  update        Update existing installation"
    echo "  audit         Scan VPS and show component status"
    echo "  malware-scan  Scan WordPress for malware & backdoors"
    echo "  firewall      Full firewall & security hardening"
    echo "  admin         Install/update admin panel only"
    echo "  version       Show version info"
    echo ""
    echo "Examples:"
    echo "  curl -sL https://qltro.com/api/vps-download | bash           # Auto-detect mode"
    echo "  vps-update update                                            # Update existing"
    echo "  vps-update audit                                             # Check status"
    echo "  vps-update malware-scan                                      # Scan for malware"
    echo "  vps-update malware-scan --auto-clean                         # Scan & auto-fix"
    echo "  vps-update firewall                                          # Harden firewall"
    echo ""
}

main() {
    show_banner

    # Check root
    if [ "$EUID" -ne 0 ]; then
        err "Please run as root: sudo $0"
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"

    local command="${1:-auto}"

    case "$command" in
        install)
            log "Mode: Full Install"
            run_audit
            local components=("nginx" "php" "mariadb" "redis" "fail2ban" "certbot" "wp-cli" "firewall" "waf" "vps-admin" "backup-system" "monitoring" "security-headers" "opcache")
            for comp in "${components[@]}"; do
                smart_install_component "$comp" "$AUDIT_OS"
            done
            echo "$VERSION" > "$VERSION_FILE"
            save_component_state
            log "✅ Full install complete!"
            ;;
        smart)
            log "Mode: Smart Install (detect existing)"
            run_audit
            if [ -n "$AUDIT_MISSING" ]; then
                echo ""
                echo -e "${BOLD}Installing ${YELLOW}only missing${NC}${BOLD} components...${NC}"
                IFS=',' read -ra MISSING <<< "$AUDIT_MISSING"
                for comp in "${MISSING[@]}"; do
                    [ -z "$comp" ] && continue
                    smart_install_component "$comp" "$AUDIT_OS"
                done
            fi
            echo "$VERSION" > "$VERSION_FILE"
            save_component_state
            log "✅ Smart install complete!"
            ;;
        update)
            log "Mode: Update"
            if check_update; then
                run_audit
                if [ -n "$AUDIT_MISSING" ]; then
                    echo -e "${YELLOW}Found missing components, installing...${NC}"
                    do_update
                fi
            else
                do_update
            fi
            ;;
        audit|check|status)
            run_audit
            ;;
        malware-scan|scan|malware)
            run_malware_scan "$2"
            ;;
        firewall|harden|security)
            harden_firewall
            ;;
        admin)
            install_admin_panel
            ;;
        version|-v|--version)
            echo "VPS 1 Chạm v${VERSION}"
            [ -f "$VERSION_FILE" ] && echo "Installed: v$(cat $VERSION_FILE)"
            ;;
        auto)
            # Auto-detect mode based on system state
            if [ -f "$VERSION_FILE" ]; then
                log "Detected existing installation, running update..."
                do_update
            else
                local panels=$(detect_existing_panels)
                if [ -n "$panels" ]; then
                    log "Detected existing setup ($panels), running smart install..."
                    run_audit
                    if [ -n "$AUDIT_MISSING" ]; then
                        echo ""
                        if [ -e /dev/tty ]; then read -p "Install missing components? (y/n): " confirm < /dev/tty; else confirm="y"; fi
                        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                            IFS=',' read -ra MISSING <<< "$AUDIT_MISSING"
                            for comp in "${MISSING[@]}"; do
                                [ -z "$comp" ] && continue
                                smart_install_component "$comp" "$AUDIT_OS"
                            done
                        fi
                    fi
                    echo "$VERSION" > "$VERSION_FILE"
                    save_component_state
                else
                    log "Fresh VPS detected, running full install..."
                    run_audit
                    echo ""
                    if [ -e /dev/tty ]; then read -p "Proceed with full install? (y/n): " confirm < /dev/tty; else confirm="y"; fi
                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                        local components=("nginx" "php" "mariadb" "redis" "fail2ban" "certbot" "wp-cli" "firewall" "waf" "vps-admin" "backup-system" "monitoring" "security-headers" "opcache")
                        for comp in "${components[@]}"; do
                            smart_install_component "$comp" "$AUDIT_OS"
                        done
                    fi
                    echo "$VERSION" > "$VERSION_FILE"
                    save_component_state
                fi
            fi
            ;;
        *)
            show_usage
            ;;
    esac
}

# Install self as vps-update command
if [ ! -f /usr/local/bin/vps-update ] || [ "$0" = "bash" ] || [ "$0" = "/bin/bash" ]; then
    curl -fsSL --retry 3 "$SCRIPT_URL/install.sh" -o /usr/local/bin/vps-update 2>/dev/null
    chmod +x /usr/local/bin/vps-update 2>/dev/null
fi

# Ensure vps-admin command is always available
if [ -f /usr/local/bin/vps-admin.sh ]; then
    ln -sf /usr/local/bin/vps-admin.sh /usr/local/bin/vps-admin 2>/dev/null
fi

main "$@"
