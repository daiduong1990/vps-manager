#!/bin/bash
# ================================================================
#  Module: Per-table MySQL Dump (Split Backup)
#  Handles GB-scale databases safely by dumping each table separately
#  with integrity checks and retry mechanism
# ================================================================

SPLIT_BACKUP_DIR="/backup/split"
SPLIT_MAX_RETRY=3

# ── MySQL auth helper (reuse from main if available) ──
_split_mysql() {
    if type _mysql &>/dev/null; then
        _mysql "$@"
    elif [ -n "$DB_ROOT_PASS" ]; then
        mysql -uroot -p"${DB_ROOT_PASS}" "$@" 2>/dev/null
    else
        mysql -uroot "$@" 2>/dev/null
    fi
}

_split_mysqldump() {
    if type _mysqldump &>/dev/null; then
        _mysqldump "$@"
    elif [ -n "$DB_ROOT_PASS" ]; then
        mysqldump -uroot -p"${DB_ROOT_PASS}" --single-transaction "$@" 2>/dev/null
    else
        mysqldump -uroot --single-transaction "$@" 2>/dev/null
    fi
}

# ── List user databases (exclude system) ──
_list_user_dbs() {
    _split_mysql -N -e "SHOW DATABASES" 2>/dev/null | grep -vE "^(information_schema|performance_schema|mysql|sys|phpmyadmin)$"
}

# ── Per-table split dump ──
backup_split_dump() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  📦  PER-TABLE SPLIT DUMP                 ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    # List databases
    local dbs=()
    while IFS= read -r db; do
        [ -n "$db" ] && dbs+=("$db")
    done < <(_list_user_dbs)

    if [ ${#dbs[@]} -eq 0 ]; then
        echo -e "  ${RED}No databases found${NC}"
        pause; return
    fi

    echo -e "  ${YELLOW}Available databases:${NC}"
    local i=1
    for db in "${dbs[@]}"; do
        local size=$(_split_mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) FROM information_schema.TABLES WHERE table_schema='${db}'" 2>/dev/null)
        [ -z "$size" ] && size="?"
        echo -e "    ${CYAN}$i)${NC} $db ${WHITE}(${size} MB)${NC}"
        ((i++))
    done
    echo -e "    ${CYAN}A)${NC} All databases"
    echo ""
    read -p "  Select database [1-${#dbs[@]}/A]: " DB_PICK

    local targets=()
    if [[ "$DB_PICK" =~ ^[Aa]$ ]]; then
        targets=("${dbs[@]}")
    elif [[ "$DB_PICK" =~ ^[0-9]+$ ]] && [ "$DB_PICK" -ge 1 ] && [ "$DB_PICK" -le "${#dbs[@]}" ]; then
        targets=("${dbs[$((DB_PICK-1))]}")
    else
        echo -e "  ${RED}Invalid selection${NC}"
        pause; return
    fi

    local DATE=$(date +%Y%m%d_%H%M%S)

    for db in "${targets[@]}"; do
        # Validate db name (security: prevent injection)
        if [[ ! "$db" =~ ^[a-zA-Z0-9_]+$ ]]; then
            echo -e "  ${RED}Skipping invalid DB name: $db${NC}"
            continue
        fi

        local DUMP_DIR="${SPLIT_BACKUP_DIR}/${db}_${DATE}"
        mkdir -p "$DUMP_DIR"

        echo ""
        echo -e "  ${WHITE}Dumping: ${CYAN}$db${NC}"

        # Get table list
        local tables=()
        while IFS= read -r tbl; do
            [ -n "$tbl" ] && tables+=("$tbl")
        done < <(_split_mysql -N -e "SHOW TABLES" "$db" 2>/dev/null)

        if [ ${#tables[@]} -eq 0 ]; then
            echo -e "    ${YELLOW}No tables found in $db${NC}"
            continue
        fi

        # Dump schema first (no data)
        echo -e "    ${WHITE}Schema...${NC}"
        _split_mysqldump --no-data --routines --triggers "$db" 2>/dev/null | gzip > "${DUMP_DIR}/_schema.sql.gz"

        local total=${#tables[@]}
        local done_count=0
        local fail_count=0
        local checksum_file="${DUMP_DIR}/_checksums.sha256"
        : > "$checksum_file"

        for tbl in "${tables[@]}"; do
            ((done_count++))
            local pct=$((done_count * 100 / total))
            local outfile="${DUMP_DIR}/${tbl}.sql.gz"

            # Retry loop
            local attempt=0
            local success=false
            while [ $attempt -lt $SPLIT_MAX_RETRY ]; do
                ((attempt++))
                printf "\r    [%3d%%] %d/%d  %-40s " "$pct" "$done_count" "$total" "$tbl"

                _split_mysqldump --quick --single-transaction \
                    --no-create-info "$db" "$tbl" 2>/dev/null | gzip > "$outfile"

                # Integrity check: file must exist and be > 20 bytes (gzip header)
                if [ -f "$outfile" ] && [ "$(stat -c%s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null)" -gt 20 ]; then
                    # Generate checksum
                    sha256sum "$outfile" >> "$checksum_file" 2>/dev/null || \
                        shasum -a 256 "$outfile" >> "$checksum_file" 2>/dev/null
                    success=true
                    break
                else
                    rm -f "$outfile"
                    [ $attempt -lt $SPLIT_MAX_RETRY ] && sleep $((attempt * 2))
                fi
            done

            if ! $success; then
                echo -e "\n    ${RED}✗ FAILED after $SPLIT_MAX_RETRY attempts: $tbl${NC}"
                ((fail_count++))
            fi
        done

        echo ""

        # Write metadata
        cat > "${DUMP_DIR}/_metadata.txt" << METAEOF
database=$db
date=$DATE
tables=$total
failed=$fail_count
hostname=$(hostname -s 2>/dev/null)
version=$(_split_mysql -N -e "SELECT VERSION()" 2>/dev/null)
METAEOF
        chmod 600 "${DUMP_DIR}/_metadata.txt" "${DUMP_DIR}/_checksums.sha256"

        local dir_size=$(du -sh "$DUMP_DIR" 2>/dev/null | awk '{print $1}')
        echo -e "    ${GREEN}✓ $db: $total tables dumped ($dir_size)${NC}"
        [ $fail_count -gt 0 ] && echo -e "    ${RED}  $fail_count table(s) failed!${NC}"
        echo -e "    ${WHITE}  → $DUMP_DIR${NC}"
    done

    echo ""
    echo -e "  ${GREEN}Split dump complete!${NC}"
    pause
}

# ── Restore from split dump ──
backup_split_restore() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  🔄  RESTORE FROM SPLIT DUMP              ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    # List available split backups
    if [ ! -d "$SPLIT_BACKUP_DIR" ]; then
        echo -e "  ${RED}No split backups found at $SPLIT_BACKUP_DIR${NC}"
        pause; return
    fi

    local dirs=()
    while IFS= read -r d; do
        [ -n "$d" ] && [ -f "$d/_metadata.txt" ] && dirs+=("$d")
    done < <(find "$SPLIT_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

    if [ ${#dirs[@]} -eq 0 ]; then
        echo -e "  ${RED}No valid split backups found${NC}"
        pause; return
    fi

    echo -e "  ${YELLOW}Available backups:${NC}"
    local i=1
    for d in "${dirs[@]}"; do
        local meta=$(cat "$d/_metadata.txt" 2>/dev/null)
        local db_name=$(echo "$meta" | grep "^database=" | cut -d= -f2)
        local bak_date=$(echo "$meta" | grep "^date=" | cut -d= -f2)
        local tbl_count=$(echo "$meta" | grep "^tables=" | cut -d= -f2)
        local dir_size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        echo -e "    ${CYAN}$i)${NC} ${WHITE}$db_name${NC} | $bak_date | $tbl_count tables | $dir_size"
        ((i++))
    done
    echo ""
    read -p "  Select backup [1-${#dirs[@]}]: " BK_PICK

    if ! [[ "$BK_PICK" =~ ^[0-9]+$ ]] || [ "$BK_PICK" -lt 1 ] || [ "$BK_PICK" -gt "${#dirs[@]}" ]; then
        echo -e "  ${RED}Invalid selection${NC}"
        pause; return
    fi

    local RESTORE_DIR="${dirs[$((BK_PICK-1))]}"
    local meta=$(cat "$RESTORE_DIR/_metadata.txt" 2>/dev/null)
    local ORIG_DB=$(echo "$meta" | grep "^database=" | cut -d= -f2)

    # Validate DB name
    if [[ ! "$ORIG_DB" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "  ${RED}Invalid database name in backup${NC}"
        pause; return
    fi

    echo ""
    read -p "  Restore to database [$ORIG_DB]: " TARGET_DB
    [ -z "$TARGET_DB" ] && TARGET_DB="$ORIG_DB"

    # Validate target DB name
    if [[ ! "$TARGET_DB" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "  ${RED}Invalid database name${NC}"
        pause; return
    fi

    # Verify checksums if available
    if [ -f "$RESTORE_DIR/_checksums.sha256" ]; then
        echo -e "  ${WHITE}Verifying checksums...${NC}"
        local check_fail=0
        while IFS= read -r line; do
            local hash=$(echo "$line" | awk '{print $1}')
            local file=$(echo "$line" | awk '{print $2}')
            [ -z "$hash" ] || [ -z "$file" ] && continue
            local actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
            [ -z "$actual" ] && actual=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')
            if [ "$hash" != "$actual" ]; then
                echo -e "    ${RED}✗ Checksum mismatch: $(basename "$file")${NC}"
                ((check_fail++))
            fi
        done < "$RESTORE_DIR/_checksums.sha256"

        if [ $check_fail -gt 0 ]; then
            echo -e "  ${RED}$check_fail file(s) corrupted! Abort restore? (Y/n): ${NC}"
            read -r ABORT
            [[ "$ABORT" != "n" ]] && { pause; return; }
        else
            echo -e "  ${GREEN}✓ All checksums verified${NC}"
        fi
    fi

    echo ""
    read -p "  Confirm restore $TARGET_DB? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && { pause; return; }

    # Create database if not exists
    _split_mysql -e "CREATE DATABASE IF NOT EXISTS \`${TARGET_DB}\`" 2>/dev/null

    # Restore schema first
    if [ -f "$RESTORE_DIR/_schema.sql.gz" ]; then
        echo -e "  ${WHITE}Restoring schema...${NC}"
        gunzip -c "$RESTORE_DIR/_schema.sql.gz" | _split_mysql "$TARGET_DB" 2>/dev/null
    fi

    # Restore each table
    local total=$(find "$RESTORE_DIR" -name '*.sql.gz' ! -name '_schema.sql.gz' 2>/dev/null | wc -l)
    local done_count=0
    local fail_count=0

    for sqlgz in "$RESTORE_DIR"/*.sql.gz; do
        [ -f "$sqlgz" ] || continue
        local tbl_name=$(basename "$sqlgz" .sql.gz)
        [ "$tbl_name" = "_schema" ] && continue

        ((done_count++))
        local pct=$((done_count * 100 / total))
        printf "\r  [%3d%%] %d/%d  Restoring %-40s " "$pct" "$done_count" "$total" "$tbl_name"

        if ! gunzip -c "$sqlgz" | _split_mysql "$TARGET_DB" 2>/dev/null; then
            echo -e "\n  ${RED}✗ Failed: $tbl_name${NC}"
            ((fail_count++))
        fi
    done

    echo ""
    echo ""
    if [ $fail_count -eq 0 ]; then
        echo -e "  ${GREEN}✓ Restored $done_count tables to $TARGET_DB${NC}"
    else
        echo -e "  ${YELLOW}⚠ Restored with $fail_count errors${NC}"
    fi
    pause
}

# ── List split backups ──
backup_split_list() {
    echo ""
    echo -e "  ${WHITE}${BOLD}Split Backups:${NC}"
    if [ ! -d "$SPLIT_BACKUP_DIR" ]; then
        echo -e "  ${YELLOW}No split backups yet${NC}"
        pause; return
    fi

    for d in "$SPLIT_BACKUP_DIR"/*/; do
        [ -f "$d/_metadata.txt" ] || continue
        local meta=$(cat "$d/_metadata.txt" 2>/dev/null)
        local db_name=$(echo "$meta" | grep "^database=" | cut -d= -f2)
        local bak_date=$(echo "$meta" | grep "^date=" | cut -d= -f2)
        local tbl_count=$(echo "$meta" | grep "^tables=" | cut -d= -f2)
        local failed=$(echo "$meta" | grep "^failed=" | cut -d= -f2)
        local dir_size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        if [ "${failed:-0}" -gt 0 ]; then
            echo -e "    ${YELLOW}●${NC} $db_name | $bak_date | $tbl_count tables | $dir_size | ${RED}$failed failed${NC}"
        else
            echo -e "    ${GREEN}●${NC} $db_name | $bak_date | $tbl_count tables | $dir_size"
        fi
    done
    pause
}

# ── Menu ──
menu_backup_split() {
    header
    echo -e "${WHITE}${BOLD}  PER-TABLE SPLIT DUMP${NC}"
    echo -e "${GREEN}  ─────────────────────────────────${NC}"
    echo -e "  ${YELLOW}For GB-scale databases — safer than single-file dump${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} Split dump (per-table backup)"
    echo -e "  ${CYAN}2.${NC} Restore from split dump"
    echo -e "  ${CYAN}3.${NC} List split backups"
    echo -e "  ${RED}0.${NC} Back"
    echo ""
    read -p "  Select: " SPLIT_CHOICE

    case $SPLIT_CHOICE in
        1) backup_split_dump ;;
        2) backup_split_restore ;;
        3) backup_split_list ;;
    esac
}
