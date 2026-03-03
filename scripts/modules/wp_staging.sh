#!/bin/bash
# ================================================================
#  Module: WordPress Staging — Clone site to staging subdomain
#  Creates staging.domain.com with .htpasswd protection
# ================================================================

# ── Clone site to staging ──
wp_staging_create() {
    echo ""
    echo -e "${BOLD}  🔄 Create Staging Clone${NC}"
    echo ""

    pick_domain "Clone which site" || return
    local DOMAIN="$PICKED_DOMAIN"

    # Find site directory
    local SITE_DIR=""
    for dir in "/home/$DOMAIN/public_html" "/var/www/$DOMAIN"; do
        [ -f "$dir/wp-config.php" ] && SITE_DIR="$dir" && break
    done

    if [ -z "$SITE_DIR" ]; then
        echo -e "  ${RED}WordPress not found for $DOMAIN${NC}"
        pause; return
    fi

    local STAGING_DOMAIN="staging.${DOMAIN}"
    local STAGING_DIR="/home/${STAGING_DOMAIN}/public_html"

    # Check if staging already exists
    if [ -d "$STAGING_DIR" ] && [ -f "$STAGING_DIR/wp-config.php" ]; then
        echo -e "  ${YELLOW}Staging already exists: $STAGING_DOMAIN${NC}"
        read -p "  Replace it? (y/N): " REPLACE
        [ "$REPLACE" != "y" ] && { pause; return; }
        rm -rf "$STAGING_DIR"
    fi

    echo -e "  ${WHITE}Creating staging: $STAGING_DOMAIN${NC}"

    # 1. Copy files
    echo -e "    ${WHITE}Copying files...${NC}"
    mkdir -p "$STAGING_DIR"
    rsync -a --exclude='.git' --exclude='node_modules' "$SITE_DIR/" "$STAGING_DIR/" 2>/dev/null
    echo -e "    ${GREEN}✓ Files copied${NC}"

    # 2. Clone database
    echo -e "    ${WHITE}Cloning database...${NC}"
    local ORIG_DB=""
    if command -v wp &>/dev/null; then
        ORIG_DB=$(wp config get DB_NAME --path="$SITE_DIR" --allow-root 2>/dev/null)
    fi
    if [ -z "$ORIG_DB" ]; then
        ORIG_DB=$(grep "DB_NAME" "$SITE_DIR/wp-config.php" 2>/dev/null | grep -oP "'[^']+'" | tail -1 | tr -d "'")
    fi

    if [ -z "$ORIG_DB" ] || [[ ! "$ORIG_DB" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "    ${RED}Cannot determine original database${NC}"
        pause; return
    fi

    local STAGING_DB="staging_$(echo "$ORIG_DB" | head -c 50)"
    local STAGING_DB_USER="stg_$(openssl rand -hex 4)"
    local STAGING_DB_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)

    # Validate generated names
    if [[ ! "$STAGING_DB" =~ ^[a-zA-Z0-9_]+$ ]] || [[ ! "$STAGING_DB_USER" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "    ${RED}Invalid generated DB name${NC}"
        pause; return
    fi

    # Create staging DB
    if type _split_mysql &>/dev/null; then
        _split_mysql -e "CREATE DATABASE IF NOT EXISTS \`${STAGING_DB}\`; CREATE USER IF NOT EXISTS '${STAGING_DB_USER}'@'localhost' IDENTIFIED BY '${STAGING_DB_PASS}'; GRANT ALL ON \`${STAGING_DB}\`.* TO '${STAGING_DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
        # Clone data
        if type _split_mysqldump &>/dev/null; then
            _split_mysqldump "$ORIG_DB" 2>/dev/null | _split_mysql "$STAGING_DB" 2>/dev/null
        fi
    elif type _mysql &>/dev/null; then
        _mysql -e "CREATE DATABASE IF NOT EXISTS \`${STAGING_DB}\`; CREATE USER IF NOT EXISTS '${STAGING_DB_USER}'@'localhost' IDENTIFIED BY '${STAGING_DB_PASS}'; GRANT ALL ON \`${STAGING_DB}\`.* TO '${STAGING_DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
        if type _mysqldump &>/dev/null; then
            _mysqldump "$ORIG_DB" 2>/dev/null | _mysql "$STAGING_DB" 2>/dev/null
        fi
    fi
    echo -e "    ${GREEN}✓ Database cloned${NC}"

    # 3. Update wp-config.php
    echo -e "    ${WHITE}Updating wp-config...${NC}"
    sed -i "s/'DB_NAME'.*/'DB_NAME', '${STAGING_DB}');/" "$STAGING_DIR/wp-config.php"
    sed -i "s/'DB_USER'.*/'DB_USER', '${STAGING_DB_USER}');/" "$STAGING_DIR/wp-config.php"
    sed -i "s/'DB_PASSWORD'.*/'DB_PASSWORD', '${STAGING_DB_PASS}');/" "$STAGING_DIR/wp-config.php"

    # Add staging flag
    if ! grep -q "WP_STAGING" "$STAGING_DIR/wp-config.php"; then
        sed -i "/DB_COLLATE/a\\define('WP_STAGING', true);\ndefine('DISALLOW_FILE_EDIT', true);\ndefine('WP_DEBUG', true);\ndefine('WP_DEBUG_LOG', true);" "$STAGING_DIR/wp-config.php"
    fi
    echo -e "    ${GREEN}✓ wp-config updated${NC}"

    # 4. Search-replace domain in DB
    if command -v wp &>/dev/null; then
        echo -e "    ${WHITE}Replacing domain in database...${NC}"
        wp search-replace "$DOMAIN" "$STAGING_DOMAIN" --path="$STAGING_DIR" --allow-root --quiet 2>/dev/null
        wp search-replace "https://$DOMAIN" "https://$STAGING_DOMAIN" --path="$STAGING_DIR" --allow-root --quiet 2>/dev/null
        echo -e "    ${GREEN}✓ Domain replaced${NC}"
    fi

    # 5. Create nginx vhost
    echo -e "    ${WHITE}Creating nginx vhost...${NC}"
    local PHP_SOCK=$(find /run -name "*.sock" -path "*php*" 2>/dev/null | head -1)
    cat > "/etc/nginx/conf.d/${STAGING_DOMAIN}.conf" << SVHOST
server {
    listen 80;
    server_name ${STAGING_DOMAIN};
    root ${STAGING_DIR};
    index index.php;

    # Basic auth protection
    auth_basic "Staging - Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd_staging;

    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location = /wp-config.php { deny all; }
    location ~ /\. { deny all; }
}
SVHOST

    # 6. Create .htpasswd
    echo -e "    ${WHITE}Setting up .htpasswd protection...${NC}"
    local STAGING_PASS=$(openssl rand -base64 8 | tr -d '/+=' | head -c 8)
    local STAGING_HASH=$(openssl passwd -apr1 "$STAGING_PASS" 2>/dev/null)
    echo "staging:${STAGING_HASH}" > /etc/nginx/.htpasswd_staging
    chmod 600 /etc/nginx/.htpasswd_staging

    # 7. Fix permissions
    chown -R nginx:nginx "$STAGING_DIR" 2>/dev/null || chown -R www-data:www-data "$STAGING_DIR"

    # 8. Test and reload nginx
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        echo -e "    ${GREEN}✓ Nginx configured${NC}"
    else
        echo -e "    ${RED}✗ Nginx config error${NC}"
        rm -f "/etc/nginx/conf.d/${STAGING_DOMAIN}.conf"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Staging created!${NC}"
    echo -e "  URL:  ${CYAN}http://$STAGING_DOMAIN${NC}"
    echo -e "  User: ${WHITE}staging${NC}"
    echo -e "  Pass: ${WHITE}$STAGING_PASS${NC}"
    echo -e ""
    echo -e "  ${YELLOW}⚠ Point DNS: $STAGING_DOMAIN → $SERVER_IP${NC}"
    echo -e "  ${YELLOW}  Or add to /etc/hosts: $SERVER_IP $STAGING_DOMAIN${NC}"
    pause
}

# ── Delete staging ──
wp_staging_delete() {
    echo ""
    echo -e "${BOLD}  🗑️ Delete Staging${NC}"
    echo ""

    # Find staging sites
    local staging_sites=()
    for conf in /etc/nginx/conf.d/staging.*.conf; do
        [ -f "$conf" ] || continue
        local sn=$(grep -m1 'server_name' "$conf" 2>/dev/null | sed 's/server_name//;s/;//' | xargs)
        [ -n "$sn" ] && staging_sites+=("$sn")
    done

    if [ ${#staging_sites[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No staging sites found${NC}"
        pause; return
    fi

    echo -e "  ${YELLOW}Staging sites:${NC}"
    local i=1
    for s in "${staging_sites[@]}"; do
        echo -e "    ${CYAN}$i)${NC} $s"
        ((i++))
    done

    echo ""
    read -p "  Delete which staging [1-${#staging_sites[@]}]: " DEL_NUM
    if ! [[ "$DEL_NUM" =~ ^[0-9]+$ ]] || [ "$DEL_NUM" -lt 1 ] || [ "$DEL_NUM" -gt "${#staging_sites[@]}" ]; then
        echo -e "  ${RED}Invalid selection${NC}"
        pause; return
    fi

    local DEL_STAGING="${staging_sites[$((DEL_NUM-1))]}"

    # Validate domain format
    if [[ ! "$DEL_STAGING" =~ ^staging\.[a-zA-Z0-9._-]+$ ]]; then
        echo -e "  ${RED}Invalid staging domain${NC}"
        pause; return
    fi

    read -p "  Confirm delete $DEL_STAGING? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && { pause; return; }

    # Get staging DB name from wp-config
    local STAGING_DIR="/home/${DEL_STAGING}/public_html"
    if [ -f "$STAGING_DIR/wp-config.php" ]; then
        local stg_db=$(grep "DB_NAME" "$STAGING_DIR/wp-config.php" 2>/dev/null | grep -oP "'[^']+'" | tail -1 | tr -d "'")
        local stg_user=$(grep "DB_USER" "$STAGING_DIR/wp-config.php" 2>/dev/null | grep -oP "'[^']+'" | tail -1 | tr -d "'")
        if [ -n "$stg_db" ] && [[ "$stg_db" =~ ^[a-zA-Z0-9_]+$ ]]; then
            if type _split_mysql &>/dev/null; then
                _split_mysql -e "DROP DATABASE IF EXISTS \`${stg_db}\`; DROP USER IF EXISTS '${stg_user}'@'localhost';" 2>/dev/null
            elif type _mysql &>/dev/null; then
                _mysql -e "DROP DATABASE IF EXISTS \`${stg_db}\`; DROP USER IF EXISTS '${stg_user}'@'localhost';" 2>/dev/null
            fi
            echo -e "  ${GREEN}✓ Staging database dropped${NC}"
        fi
    fi

    # Remove files
    rm -rf "/home/${DEL_STAGING}"
    rm -f "/etc/nginx/conf.d/${DEL_STAGING}.conf"
    nginx -t 2>/dev/null && systemctl reload nginx

    echo -e "  ${GREEN}✓ Staging $DEL_STAGING deleted${NC}"
    pause
}

# ── Menu ──
menu_wp_staging() {
    header
    echo -e "${WHITE}${BOLD}  WORDPRESS STAGING${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} Create staging clone"
    echo -e "  ${CYAN}2.${NC} Delete staging site"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " STG_CHOICE

    case $STG_CHOICE in
        1) wp_staging_create ;;
        2) wp_staging_delete ;;
    esac
}
