#!/bin/bash
# ================================================================
#  Module: SSH Key Manager
#  Add/remove SSH keys, toggle password auth, hardening
# ================================================================

AUTH_KEYS="/root/.ssh/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# ── Validate SSH public key format ──
_validate_ssh_key() {
    local key="$1"
    # Must start with a known key type
    if ! echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256) '; then
        echo -e "  ${RED}Invalid SSH key format${NC}"
        echo -e "  ${YELLOW}Key must start with: ssh-rsa, ssh-ed25519, or ecdsa-sha2-*${NC}"
        return 1
    fi
    # Basic length check (min 80 chars for any valid key)
    if [ ${#key} -lt 80 ]; then
        echo -e "  ${RED}Key too short — likely invalid${NC}"
        return 1
    fi
    # No dangerous characters (prevent injection)
    if echo "$key" | grep -qE '[;&|$`\\]'; then
        echo -e "  ${RED}Key contains invalid characters${NC}"
        return 1
    fi
    return 0
}

# ── List keys ──
ssh_list_keys() {
    echo ""
    echo -e "  ${WHITE}${BOLD}Authorized SSH Keys:${NC}"
    echo ""

    if [ ! -f "$AUTH_KEYS" ] || [ ! -s "$AUTH_KEYS" ]; then
        echo -e "  ${YELLOW}No authorized keys found${NC}"
        return
    fi

    local i=1
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        local key_type=$(echo "$line" | awk '{print $1}')
        local key_comment=$(echo "$line" | awk '{print $3}')
        # Generate fingerprint
        local fingerprint=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')

        echo -e "    ${CYAN}$i)${NC} ${WHITE}$key_type${NC}"
        [ -n "$fingerprint" ] && echo -e "       Fingerprint: ${CYAN}$fingerprint${NC}"
        [ -n "$key_comment" ] && echo -e "       Comment: $key_comment"
        ((i++))
    done < "$AUTH_KEYS"

    [ $i -eq 1 ] && echo -e "  ${YELLOW}No valid keys found${NC}"
}

# ── Add key ──
ssh_add_key() {
    echo ""
    echo -e "  ${WHITE}Paste SSH public key (one line):${NC}"
    echo ""
    read -r NEW_KEY

    if [ -z "$NEW_KEY" ]; then
        echo -e "  ${RED}No key provided${NC}"
        pause; return
    fi

    _validate_ssh_key "$NEW_KEY" || { pause; return; }

    # Check for duplicate
    if [ -f "$AUTH_KEYS" ] && grep -qF "$(echo "$NEW_KEY" | awk '{print $2}')" "$AUTH_KEYS" 2>/dev/null; then
        echo -e "  ${YELLOW}Key already exists${NC}"
        pause; return
    fi

    # Ensure .ssh directory exists with correct permissions
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    echo "$NEW_KEY" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    echo -e "  ${GREEN}✓ SSH key added${NC}"
    pause
}

# ── Remove key ──
ssh_remove_key() {
    ssh_list_keys
    echo ""

    local key_count=$(grep -cvE '^(#|$)' "$AUTH_KEYS" 2>/dev/null)
    if [ "${key_count:-0}" -eq 0 ]; then
        pause; return
    fi

    # Safety: prevent removing last key if password auth is disabled
    local pass_auth=$(grep -E "^PasswordAuthentication" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    if [ "${key_count:-0}" -le 1 ] && [ "$pass_auth" = "no" ]; then
        echo -e "  ${RED}⚠ Cannot remove last key — password auth is disabled!${NC}"
        echo -e "  ${YELLOW}  Enable password auth first, or you'll be locked out.${NC}"
        pause; return
    fi

    read -p "  Key number to remove: " REM_NUM
    if ! [[ "$REM_NUM" =~ ^[0-9]+$ ]] || [ "$REM_NUM" -lt 1 ] || [ "$REM_NUM" -gt "$key_count" ]; then
        echo -e "  ${RED}Invalid selection${NC}"
        pause; return
    fi

    # Backup before removal
    cp "$AUTH_KEYS" "${AUTH_KEYS}.bak.$(date +%Y%m%d%H%M%S)"

    # Remove the Nth non-comment, non-empty line
    local current=0
    local tmpfile=$(mktemp)
    while IFS= read -r line; do
        if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
            echo "$line" >> "$tmpfile"
            continue
        fi
        ((current++))
        if [ "$current" -ne "$REM_NUM" ]; then
            echo "$line" >> "$tmpfile"
        fi
    done < "$AUTH_KEYS"
    mv "$tmpfile" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    echo -e "  ${GREEN}✓ Key removed${NC}"
    pause
}

# ── Toggle password auth ──
ssh_toggle_password() {
    echo ""

    local current=$(grep -E "^PasswordAuthentication" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    [ -z "$current" ] && current="yes"

    if [ "$current" = "yes" ]; then
        echo -e "  Password auth: ${GREEN}ENABLED${NC}"
        echo ""
        # Check if keys exist before allowing disable
        local key_count=$(grep -cvE '^(#|$)' "$AUTH_KEYS" 2>/dev/null)
        if [ "${key_count:-0}" -eq 0 ]; then
            echo -e "  ${RED}⚠ No SSH keys found! Add a key first before disabling password auth.${NC}"
            pause; return
        fi
        read -p "  Disable password auth? (y/N): " DISABLE
        if [ "$DISABLE" = "y" ]; then
            # Backup sshd_config
            cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

            if grep -qE "^PasswordAuthentication" "$SSHD_CONFIG"; then
                sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
            elif grep -qE "^#PasswordAuthentication" "$SSHD_CONFIG"; then
                sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
            else
                echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
            fi

            # Validate config before restart
            if sshd -t 2>/dev/null; then
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
                echo -e "  ${GREEN}✓ Password auth DISABLED — key-only access${NC}"
            else
                echo -e "  ${RED}✗ sshd config error — reverting!${NC}"
                local latest_bak=$(ls -t "${SSHD_CONFIG}.bak."* 2>/dev/null | head -1)
                [ -n "$latest_bak" ] && cp "$latest_bak" "$SSHD_CONFIG"
                sshd -t 2>/dev/null && systemctl restart sshd 2>/dev/null
            fi
        fi
    else
        echo -e "  Password auth: ${RED}DISABLED${NC}"
        echo ""
        read -p "  Enable password auth? (y/N): " ENABLE
        if [ "$ENABLE" = "y" ]; then
            cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
            sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"

            if sshd -t 2>/dev/null; then
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
                echo -e "  ${GREEN}✓ Password auth ENABLED${NC}"
            else
                echo -e "  ${RED}✗ sshd config error — reverting!${NC}"
                local latest_bak=$(ls -t "${SSHD_CONFIG}.bak."* 2>/dev/null | head -1)
                [ -n "$latest_bak" ] && cp "$latest_bak" "$SSHD_CONFIG"
                sshd -t 2>/dev/null && systemctl restart sshd 2>/dev/null
            fi
        fi
    fi
    pause
}

# ── Menu ──
menu_ssh_keys() {
    header
    echo -e "${WHITE}${BOLD}  SSH KEY MANAGER${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} List authorized keys"
    echo -e "  ${CYAN}2.${NC} Add SSH key"
    echo -e "  ${CYAN}3.${NC} Remove SSH key"
    echo -e "  ${CYAN}4.${NC} Toggle password authentication"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " SSH_CHOICE

    case $SSH_CHOICE in
        1) ssh_list_keys; pause ;;
        2) ssh_add_key ;;
        3) ssh_remove_key ;;
        4) ssh_toggle_password ;;
    esac
}
