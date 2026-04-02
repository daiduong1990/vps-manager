#!/bin/bash
# ================================================================
#  Module: omni_shield.sh
#  Omni-Shield: TCP BBR + Swap + Firewall + Nginx Hardening
#  Usage: sourced by vps-admin.sh
# ================================================================

menu_omni_shield() {
    while true; do
        header
        echo -e "${WHITE}${BOLD}  🛡️  OMNI-SHIELD — Hardening & Performance${NC}"
        echo -e "${GREEN}  ─────────────────────────────────${NC}"

        # Live status indicators
        local bbr_status tcp_cc bbr_icon swap_total ufw_status f2b_icon
        tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        [[ "$tcp_cc" == "bbr" ]] && bbr_icon="${GREEN}✓ BBR Active${NC}" || bbr_icon="${RED}✗ BBR Not Set (${tcp_cc})${NC}"

        swap_total=$(free -h | awk '/Swap/{print $2}')
        [[ "$swap_total" == "0B" ]] && swap_icon="${RED}✗ No Swap${NC}" || swap_icon="${GREEN}✓ Swap: $swap_total${NC}"

        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
            ufw_icon="${GREEN}✓ UFW Active${NC}"
        elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
            ufw_icon="${GREEN}✓ Firewalld Active${NC}"
        else
            ufw_icon="${RED}✗ No Firewall${NC}"
        fi

        f2b_icon="${RED}✗ Fail2Ban Stopped${NC}"
        systemctl is-active fail2ban &>/dev/null && f2b_icon="${GREEN}✓ Fail2Ban Running${NC}"

        echo -e "  Status: TCP $bbr_icon  |  $swap_icon"
        echo -e "  Firewall: $ufw_icon  |  $f2b_icon"
        echo -e "${GREEN}  ─────────────────────────────────${NC}"
        echo -e "  ${CYAN}1.${NC} ⚡ Enable TCP BBR (Google congestion control)"
        echo -e "  ${CYAN}2.${NC} 💾 Add 4GB Swap (anti-OOM)"
        echo -e "  ${CYAN}3.${NC} 🔒 Harden Firewall (lock ports)"
        echo -e "  ${CYAN}4.${NC} 🔄 Fix Fail2Ban + Enable Nginx Access Logs"
        echo -e "  ${CYAN}5.${NC} 🚀 Full Omni-Shield (run all above)"
        echo -e "  ${CYAN}6.${NC} 🧟 Kill Nginx Zombie Process (100% CPU fix)"
        echo -e "  ${CYAN}7.${NC} 📊 Check Fail2Ban ban stats"
        echo -e "  ${RED}0.${NC} Back"
        echo ""
        read -p "  Select: " SHIELD_CHOICE

        case $SHIELD_CHOICE in
            1) do_enable_bbr ;;
            2) do_add_swap ;;
            3) do_harden_firewall ;;
            4) do_fix_fail2ban ;;
            5) do_full_omni_shield ;;
            6) do_kill_nginx_zombie ;;
            7) do_fail2ban_stats ;;
            0) break ;;
        esac
    done
}

do_enable_bbr() {
    echo ""
    local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current" == "bbr" ]]; then
        echo -e "  ${GREEN}✓ TCP BBR already active${NC}"
        pause; return
    fi
    echo -e "  ${YELLOW}Enabling TCP BBR...${NC}"
    cat > /etc/sysctl.d/99-bbr.conf << 'BBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBR
    sysctl --system &>/dev/null
    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$new_cc" == "bbr" ]]; then
        echo -e "  ${GREEN}✓ TCP BBR enabled! Network throughput +15-25%${NC}"
    else
        echo -e "  ${RED}✗ BBR not supported on this kernel. Try upgrading kernel.${NC}"
    fi
    pause
}

do_add_swap() {
    echo ""
    local current_swap=$(free -m | awk '/Swap/{print $2}')
    if [[ "$current_swap" -gt 1024 ]]; then
        echo -e "  ${GREEN}✓ Swap already exists: $(free -h | awk '/Swap/{print $2}')${NC}"
        pause; return
    fi
    echo -e "  ${YELLOW}Creating 4GB swap file...${NC}"
    if [ -f /swapfile ]; then
        swapoff /swapfile &>/dev/null
        rm -f /swapfile
    fi
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    # Persist across reboots
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    # Tune swappiness to avoid disk thrash
    sysctl vm.swappiness=10 &>/dev/null
    grep -q 'vm.swappiness' /etc/sysctl.d/99-bbr.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.d/99-bbr.conf
    echo -e "  ${GREEN}✓ 4GB Swap activated! (vm.swappiness=10)${NC}"
    free -h | awk '/Swap/{print "  Swap: "$2" total"}'
    pause
}

do_harden_firewall() {
    echo ""
    echo -e "  ${YELLOW}Hardening firewall. Open ports: 2222(SSH) 80 443 3000 3001${NC}"
    read -p "  SSH port [2222]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-2222}"
    [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] && SSH_PORT=2222

    if command -v ufw &>/dev/null; then
        ufw --force reset &>/dev/null
        ufw default deny incoming &>/dev/null
        ufw default allow outgoing &>/dev/null
        ufw allow "${SSH_PORT}/tcp" &>/dev/null
        ufw allow 80/tcp &>/dev/null
        ufw allow 443/tcp &>/dev/null
        ufw allow 3000/tcp &>/dev/null
        ufw allow 3001/tcp &>/dev/null
        ufw --force enable &>/dev/null
        echo -e "  ${GREEN}✓ UFW firewall hardened${NC}"
        ufw status numbered
    elif command -v firewall-cmd &>/dev/null; then
        systemctl enable firewalld --now &>/dev/null
        firewall-cmd --set-default-zone=drop &>/dev/null
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" &>/dev/null
        firewall-cmd --permanent --add-service=http &>/dev/null
        firewall-cmd --permanent --add-service=https &>/dev/null
        firewall-cmd --permanent --add-port=3000/tcp &>/dev/null
        firewall-cmd --permanent --add-port=3001/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        echo -e "  ${GREEN}✓ Firewalld hardened${NC}"
    else
        echo -e "  ${RED}✗ No firewall found. Install ufw: apt install ufw${NC}"
    fi
    pause
}

do_fix_fail2ban() {
    echo ""
    echo -e "  ${YELLOW}Enabling Nginx access logs for Fail2Ban...${NC}"
    # Re-enable access logs that may have been silenced
    local changed=0
    for conf in /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue
        if grep -q 'access_log.*off' "$conf" 2>/dev/null; then
            sed -i 's/access_log.*off;/# access_log off; # re-enabled by omni-shield/g' "$conf"
            ((changed++))
        fi
    done
    [ $changed -gt 0 ] && echo -e "  ${GREEN}✓ Re-enabled logs on $changed Nginx configs${NC}" || echo -e "  ${CYAN}ℹ  Logs were already enabled${NC}"

    # Ensure Fail2Ban is running
    if systemctl is-active fail2ban &>/dev/null; then
        echo -e "  ${GREEN}✓ Fail2Ban already running${NC}"
    else
        systemctl enable fail2ban --now &>/dev/null
        echo -e "  ${GREEN}✓ Fail2Ban started${NC}"
    fi

    # Verify sshd jail
    if fail2ban-client status sshd &>/dev/null; then
        echo -e "  ${GREEN}✓ fail2ban jail [sshd] active${NC}"
    else
        echo -e "  ${YELLOW}⚠ sshd jail might need config. Check /etc/fail2ban/jail.local${NC}"
    fi

    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    echo -e "  ${GREEN}✓ Nginx reloaded${NC}"
    pause
}

do_full_omni_shield() {
    echo ""
    echo -e "  ${WHITE}${BOLD}🛡️  RUNNING FULL OMNI-SHIELD PROTOCOL...${NC}"
    echo -e "  ${YELLOW}This will secure and optimize this VPS.${NC}"
    read -p "  Continue? (y/N): " C
    [ "$C" != "y" ] && return

    echo ""
    echo -e "  ${CYAN}[1/4] TCP BBR...${NC}"
    do_enable_bbr 2>/dev/null

    echo -e "  ${CYAN}[2/4] Swap...${NC}"
    # Inline to avoid pause
    local current_swap=$(free -m | awk '/Swap/{print $2}')
    if [[ "$current_swap" -lt 1024 ]]; then
        fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
        chmod 600 /swapfile; mkswap /swapfile &>/dev/null; swapon /swapfile &>/dev/null
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "  ${GREEN}✓ 4GB Swap ready${NC}"
    else
        echo -e "  ${GREEN}✓ Swap already exists${NC}"
    fi

    echo -e "  ${CYAN}[3/4] Firewall...${NC}"
    if command -v ufw &>/dev/null; then
        ufw --force reset &>/dev/null
        ufw default deny incoming &>/dev/null
        ufw allow 2222/tcp &>/dev/null
        ufw allow 80/tcp &>/dev/null
        ufw allow 443/tcp &>/dev/null
        ufw allow 3000/tcp &>/dev/null
        ufw allow 3001/tcp &>/dev/null
        ufw --force enable &>/dev/null
        echo -e "  ${GREEN}✓ UFW locked${NC}"
    elif command -v firewall-cmd &>/dev/null; then
        systemctl enable firewalld --now &>/dev/null
        firewall-cmd --set-default-zone=drop &>/dev/null
        firewall-cmd --permanent --add-port=2222/tcp &>/dev/null
        firewall-cmd --permanent --add-service={http,https} &>/dev/null
        firewall-cmd --permanent --add-port=3000-3001/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        echo -e "  ${GREEN}✓ Firewalld locked${NC}"
    fi

    echo -e "  ${CYAN}[4/4] Fail2Ban + Nginx logs...${NC}"
    for conf in /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue
        grep -q 'access_log.*off' "$conf" 2>/dev/null && \
            sed -i 's/access_log.*off;/# access_log off;/g' "$conf"
    done
    systemctl enable fail2ban --now &>/dev/null
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    echo -e "  ${GREEN}✓ Fail2Ban + Logs fixed${NC}"

    echo ""
    echo -e "  ${GREEN}${BOLD}✅ OMNI-SHIELD ACTIVE — VPS is hardened!${NC}"
    echo -e "  BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "  Swap: $(free -h | awk '/Swap/{print $2}')"
    pause
}

do_kill_nginx_zombie() {
    echo ""
    echo -e "  ${YELLOW}Killing Nginx zombie processes (100% CPU fix)...${NC}"
    local nginx_cpu
    nginx_cpu=$(ps aux | grep nginx | awk '{print $3}' | sort -rn | head -1)
    echo -e "  Top Nginx CPU: ${nginx_cpu}%"
    systemctl kill -s SIGKILL nginx 2>/dev/null
    sleep 1
    systemctl start nginx 2>/dev/null
    if systemctl is-active nginx &>/dev/null; then
        echo -e "  ${GREEN}✓ Nginx restarted cleanly${NC}"
    else
        echo -e "  ${RED}✗ Nginx failed to start. Check: systemctl status nginx${NC}"
    fi
    pause
}

do_fail2ban_stats() {
    echo ""
    echo -e "  ${WHITE}${BOLD}  Fail2Ban Status:${NC}"
    fail2ban-client status 2>/dev/null || echo -e "  ${RED}Fail2Ban not running${NC}"
    echo ""
    echo -e "  ${WHITE}${BOLD}  SSHD Jail:${NC}"
    fail2ban-client status sshd 2>/dev/null || echo -e "  ${YELLOW}sshd jail not configured${NC}"
    echo ""
    echo -e "  ${WHITE}${BOLD}  Recent Bans (last 20):${NC}"
    grep 'Ban ' /var/log/fail2ban.log 2>/dev/null | tail -20 || echo "  (no log found)"
    pause
}
