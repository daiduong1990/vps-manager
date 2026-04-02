#!/bin/bash
# ================================================================
# System & DB Cleaner Module for VPS Manager
# ================================================================

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'
export NC='\033[0m'
export BOLD='\033[1m'

clean_wp_db() {
    echo -e "${CYAN}>> Dọn dẹp WordPress Database...${NC}"
    for dir in $(find /home /var/www -maxdepth 3 -type d -name "public_html" 2>/dev/null); do
        if [ -f "$dir/wp-config.php" ]; then
            domain=$(basename $(dirname "$dir"))
            echo -e "   ${BOLD}[$domain]${NC}"
            
            # Xoá revisions, spam, trash, auto-drafts
            wp post delete $(wp post list --post_type='post,page,product' --post_status='trash,auto-draft' --format=ids --path="$dir" --allow-root 2>/dev/null) --force --path="$dir" --allow-root 2>/dev/null | grep -v 'Warning'
            wp post delete $(wp post list --post_type='revision' --format=ids --path="$dir" --allow-root 2>/dev/null) --force --path="$dir" --allow-root 2>/dev/null | grep -v 'Warning'
            wp transient delete --expired --path="$dir" --allow-root 2>/dev/null
            wp transient delete --all --path="$dir" --allow-root 2>/dev/null
            
            # Tối ưu hoá DB table (Defragmentation)
            wp db optimize --path="$dir" --allow-root 2>/dev/null
            echo -e "   ${GREEN}✓ Đã tối ưu Database cho $domain${NC}"
        fi
    done
}

clean_sys_logs() {
    echo -e "${CYAN}>> Dọn dẹp System Logs & Caches...${NC}"
    
    # 1. Dọn systemd journal logs (Giữ lại 50MB)
    journalctl --vacuum-size=50M >/dev/null 2>&1
    echo -e "   ${GREEN}✓ Đã dọn dẹp Journald logs${NC}"
    
    # 2. Xóa Nginx & PHP old logs (.gz)
    find /var/log/nginx -name "*.gz" -type f -delete 2>/dev/null
    find /var/log/nginx -name "*.1" -type f -delete 2>/dev/null
    find /var/log/php* -name "*.gz" -type f -delete 2>/dev/null
    find /var/log/php* -name "*.1" -type f -delete 2>/dev/null
    echo -e "   ${GREEN}✓ Đã xoá Nginx & PHP-FPM archive logs${NC}"
    
    # 3. Clear apt/yum cache
    if command -v apt-get &> /dev/null; then
        apt-get clean >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yum clean all >/dev/null 2>&1
    fi
    echo -e "   ${GREEN}✓ Đã dọn dẹp Package Manager Cache${NC}"
}

setup_auto_clean() {
    cron_cmd="/usr/local/bin/vps-admin clean all > /dev/null 2>&1"
    if crontab -l 2>/dev/null | grep -q "$cron_cmd"; then
        echo -e "${YELLOW}Cronjob tự động dọn dẹp đã được cài đặt từ trước.${NC}"
    else
        # Chạy vào lúc 03:00 AM Chủ Nhật hàng tuần
        (crontab -l 2>/dev/null; echo "0 3 * * 0 $cron_cmd") | crontab -
        echo -e "${GREEN}Đã cài đặt Cronjob: Tự động chạy System Cleaner vào 03:00 AM Chủ Nhật hàng tuần.${NC}"
    fi
}

menu_system_cleaner() {
    while true; do
        echo -e "\n${BOLD}╔═══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║      🧹 TRÌNH DỌN DẸP & TỐI ƯU HỆ THỐNG   ║${NC}"
        echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
        echo -e "  1. 🗄️  Dọn dẹp & Tối ưu Database (WP Transients, Revisions)"
        echo -e "  2. 📝 Xoá file Logs hệ thống (Nginx, PHP, Journald)"
        echo -e "  3. 🚀 Chạy toàn bộ (Full Cleanup)"
        echo -e "  4. ⏰ Bật tự động dọn dẹp (Cronjob 3h sáng CN)"
        echo -e "  0. 🔙 Quay lại menu chính"
        echo -e "─────────────────────────────────────────────"
        read -p "Chọn tùy chọn (0-4): " clean_choice

        case $clean_choice in
            1) clean_wp_db ;;
            2) clean_sys_logs ;;
            3) 
               clean_sys_logs
               clean_wp_db
               ;;
            4) setup_auto_clean ;;
            0) break ;;
            *) echo -e "${RED}Lựa chọn không hợp lệ!${NC}" ;;
        esac
        
        echo -e "\nNhấn Enter để tiếp tục..."
        read
        clear
    done
}

# Auto trigger for CLI arguments
if [ "$1" == "all" ]; then
    clean_sys_logs
    clean_wp_db
fi
