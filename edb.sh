#!/usr/bin/env bash
set -euo pipefail

#############################################
### LOAD CONFIG IF EXISTS (.env)
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

#############################################
### DEFAULTS (used if .env missing)
#############################################

SERVER_URL="${EDB_SERVER_URL:-http://localhost:8080/exist}"
USER="${EDB_USER:-admin}"
PASS="${EDB_PASS:-password}"
EXIST_COLLECTION="${EDB_COLLECTION:-/db/apps/sympa}"
LOCAL_DIR="${EDB_LOCAL_DIR:-./sympa}"

REST_BASE="$SERVER_URL/rest"

### XAR defaults
XAR_NAME="${EDB_XAR_NAME:-$(basename "$EXIST_COLLECTION")}"
XAR_DIST_DIR="${EDB_XAR_DIST_DIR:-$SCRIPT_DIR/dist}"

### BACKUP defaults
BACKUP_DIR="${EDB_BACKUP_DIR:-$SCRIPT_DIR/backups}"
BACKUP_KEEP="${EDB_BACKUP_KEEP:-10}"   # max number of backups to keep

#############################################
### HELP
#############################################

usage() {
    echo "eXist-DB CLI"
    echo
    echo "Usage:"
    echo "  edb init           create .env config"
    echo "  edb edit           edit .env"
    echo "  edb export         export from eXist → local"
    echo "  edb import         import from local → eXist (auto-backup first)"
    echo "  edb watch          watch local dir and auto-import changes"
    echo "  edb build-xar      build XAR package from local dir"
    echo "  edb backup         backup remote collection → backups dir"
    echo "  edb rollback last  restore from latest backup"
    echo "  edb rollback <ts>  restore from specific backup timestamp"
    echo
}

#############################################
### INIT CONFIG FILE
#############################################

do_init() {
    if [[ -f "$ENV_FILE" ]]; then
        echo ".env already exists — remove it if you want to regenerate."
        exit 1
    fi

    {
        echo 'EDB_SERVER_URL="http://localhost:8080/exist"'
        echo 'EDB_USER="admin"'
        echo 'EDB_PASS="password"'
        echo 'EDB_COLLECTION="/db/apps/sympa"'
        echo 'EDB_LOCAL_DIR="./sympa"'
        echo
        echo '# Optional XAR settings:'
        echo '# EDB_XAR_NAME="sympa"'
        echo '# EDB_XAR_DIST_DIR="./dist"'
        echo '# EDB_XAR_VERSION="0.0.1"'
        echo
        echo '# Optional backup settings:'
        echo '# EDB_BACKUP_DIR="./backups"'
        echo '# EDB_BACKUP_KEEP=10'
    } > "$ENV_FILE"

    echo "Created .env — adjust it, then run:"
    echo "   edb export   or   edb import"
}

#############################################
### EDIT ENV
#############################################

do_edit() {
    [[ ! -f "$ENV_FILE" ]] && echo "Run 'edb init' first." && exit 1
    ${EDITOR:-nano} "$ENV_FILE"
}

#############################################
### SMALL URL ENCODER (spaces → %20)
#############################################

url_encode() {
    local s="$1"
    s="${s// /%20}"
    echo "$s"
}

#############################################
### EXPORT — via REST, recursive
#############################################

do_export() {

    echo "📥 Exporting via REST"
    echo "Root:   $EXIST_COLLECTION"
    echo "Output: $LOCAL_DIR"

    mkdir -p "$LOCAL_DIR"

    local ROOT="$EXIST_COLLECTION"
    ROOT="${ROOT%/}"

    crawl() {
        local dbpath="$1"

        # relative path based on ROOT
        local rel="${dbpath#$ROOT}"
        rel="${rel#/}"
        [[ -z "$rel" ]] && rel="."

        mkdir -p "$LOCAL_DIR/$rel"

        local listing
        listing="$(mktemp)"
        curl -s -u "$USER:$PASS" "$REST_BASE$dbpath" > "$listing"

        # ---- FILES ----
        sed -n 's/.*resource name="\([^"]*\)".*/\1/p' "$listing" |
        while read -r name; do
            [[ -z "$name" ]] && continue
            # skip directory entries (they also appear as collections)
            if grep -q "collection name=\"$name\"" "$listing"; then
                continue
            fi

            echo "⬇ $rel/$name"
            curl -s -u "$USER:$PASS" \
                 "$REST_BASE$dbpath/$name" \
                 -o "$LOCAL_DIR/$rel/$name"
        done

        # ---- DIRECTORIES (with simple loop guard) ----
        sed -n 's/.*collection name="\([^"]*\)".*/\1/p' "$listing" |
        while read -r dir; do
            [[ -z "$dir" ]] && continue
            local next="$dbpath/$dir"

            # if ROOT appears more than once → possible recursion, stop
            if [[ "$(grep -o "$ROOT" <<< "$next" | wc -l)" -gt 1 ]]; then
                echo "⛔ STOP LOOP → $next"
                continue
            fi

            echo "📂 $rel/$dir"
            crawl "$next"
        done

        rm -f "$listing"
    }

    crawl "$ROOT"

    echo "✔ EXPORT COMPLETE → $(cd "$LOCAL_DIR" && pwd)"
}

#############################################
### BACKUP — export remote collection → backups dir
#############################################

do_backup() {
    echo "🛟 Creating backup of remote collection"
    echo "Remote:  $EXIST_COLLECTION"
    echo "Backups: $BACKUP_DIR"

    local app_name="$XAR_NAME"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"

    # e.g. ./backups/sympa/20250218_153012
    local target_root="$BACKUP_DIR/$app_name/$ts"

    mkdir -p "$target_root"

    local ROOT="$EXIST_COLLECTION"
    ROOT="${ROOT%/}"

    crawl_backup() {
        local dbpath="$1"

        local rel="${dbpath#$ROOT}"
        rel="${rel#/}"
        [[ -z "$rel" ]] && rel="."

        mkdir -p "$target_root/$rel"

        local listing
        listing="$(mktemp)"
        curl -s -u "$USER:$PASS" "$REST_BASE$dbpath" > "$listing"

        # ---- FILES ----
        sed -n 's/.*resource name="\([^"]*\)".*/\1/p' "$listing" |
        while read -r name; do
            [[ -z "$name" ]] && continue
            if grep -q "collection name=\"$name\"" "$listing"; then
                continue
            fi

            echo "⬇ [backup] $rel/$name"
            curl -s -u "$USER:$PASS" \
                 "$REST_BASE$dbpath/$name" \
                 -o "$target_root/$rel/$name"
        done

        # ---- DIRECTORIES ----
        sed -n 's/.*collection name="\([^"]*\)".*/\1/p' "$listing" |
        while read -r dir; do
            [[ -z "$dir" ]] && continue
            local next="$dbpath/$dir"
            echo "📂 [backup] $rel/$dir"
            crawl_backup "$next"
        done

        rm -f "$listing"
    }

    crawl_backup "$ROOT"

    echo "✔ BACKUP COMPLETE → $target_root"

    # ---- BACKUP ROTATION ----
    if [[ "$BACKUP_KEEP" -gt 0 ]] && [[ -d "$BACKUP_DIR/$app_name" ]]; then
        mapfile -t backups < <(ls -1d "$BACKUP_DIR/$app_name"/* 2>/dev/null | sort)
        local count="${#backups[@]}"

        if (( count > BACKUP_KEEP )); then
            local to_delete=$((count - BACKUP_KEEP))
            echo "🧹 Rotating backups (keep=$BACKUP_KEEP, total=$count)"

            for ((i=0; i<to_delete; i++)); do
                echo "   rm -rf ${backups[$i]}"
                rm -rf "${backups[$i]}"
            done
        fi
    fi
}

#############################################
### INTERNAL: sync arbitrary dir → eXist
#############################################

sync_dir_to_exist() {
    local SRC_DIR="$1"

    [[ ! -d "$SRC_DIR" ]] && echo "Source dir not found: $SRC_DIR" && exit 1

    echo "📂 Creating collections in eXist from: $SRC_DIR"

    find "$SRC_DIR" -type d | while read -r dir; do
        local rel="${dir#$SRC_DIR}"
        rel="${rel#/}"   # strip leading /

        local dbpath="$EXIST_COLLECTION"
        if [[ -n "$rel" ]]; then
            dbpath="$dbpath/$rel"
        fi

        local enc_path
        enc_path=$(url_encode "$dbpath")

        curl -s -u "$USER:$PASS" -X MKCOL "$REST_BASE$enc_path" >/dev/null 2>&1 || true
    done

    echo "⬆ Uploading files (overwrite enabled)..."

    find "$SRC_DIR" -type f \
        ! -name '.DS_Store' \
        ! -path '*/.git/*' \
        ! -path '*/.idea/*' \
        | while read -r file; do

        local rel="${file#$SRC_DIR}"
        rel="${rel#/}"

        local enc_rel
        enc_rel=$(url_encode "$rel")

        local dest="$REST_BASE$EXIST_COLLECTION/$enc_rel"

        echo "PUT $rel"
        curl -s -u "$USER:$PASS" -X PUT -T "$file" "$dest" >/dev/null
    done
}

#############################################
### IMPORT — from local dir → eXist (with backup)
#############################################

do_import() {

    echo "📤 Importing to eXist"
    echo "Source: $LOCAL_DIR"
    echo "Target: $EXIST_COLLECTION"

    [[ ! -d "$LOCAL_DIR" ]] && echo "Local dir not found: $LOCAL_DIR" && exit 1

    echo "🛟 Auto-backup → exporting remote collection before import..."
    do_backup
    echo "🛟 Backup completed. Proceeding with import."

    sync_dir_to_exist "$LOCAL_DIR"

    echo "✔ IMPORT COMPLETE to $EXIST_COLLECTION"
}

#############################################
### BUILD XAR — package LOCAL_DIR into .xar
#############################################

do_build_xar() {

    echo "📦 Building XAR package"
    echo "Source dir: $LOCAL_DIR"
    echo "App name:   $XAR_NAME"
    echo "Output dir: $XAR_DIST_DIR"

    [[ ! -d "$LOCAL_DIR" ]] && echo "Local dir not found: $LOCAL_DIR" && exit 1

    if ! command -v zip >/dev/null 2>&1; then
        echo "❌ 'zip' command not found. Install it first (e.g. 'sudo apt-get install zip' or 'brew install zip')."
        exit 1
    fi

    mkdir -p "$XAR_DIST_DIR"

    local XAR_DIST_DIR_ABS
    XAR_DIST_DIR_ABS="$(cd "$XAR_DIST_DIR" && pwd)"

    local ts
    ts="$(date +%Y%m%d_%H%M%S)"

    local version="${EDB_XAR_VERSION:-$ts}"

    local xar_path="$XAR_DIST_DIR_ABS/${XAR_NAME}-${version}.xar"

    echo "➡ Output file: $xar_path"

    (
        cd "$LOCAL_DIR"
        zip -rq "$xar_path" .
    )

    echo "✔ XAR created: $xar_path"

    local latest="$XAR_DIST_DIR_ABS/${XAR_NAME}-latest.xar"
    if command -v ln >/dev/null 2>&1; then
        ln -sf "$(basename "$xar_path")" "$latest" 2>/dev/null || cp "$xar_path" "$latest"
    else
        cp "$xar_path" "$latest"
    fi
    echo "🔁 Symlink/copy updated: $latest"
}

#############################################
### WATCH — auto-upload on file change
#############################################

do_watch() {

    echo "👀 Watch mode ON"
    echo "Watching: $LOCAL_DIR"
    echo "Target:   $EXIST_COLLECTION"
    echo "Every change to a file will be uploaded automatically."
    echo

    [[ ! -d "$LOCAL_DIR" ]] && echo "Local dir not found: $LOCAL_DIR" && exit 1

    local watcher=""
    if command -v fswatch >/dev/null 2>&1; then
        watcher="fswatch"
    elif command -v inotifywait >/dev/null 2>&1; then
        watcher="inotifywait"
    else
        echo "❌ No watcher found."
        echo "Install one of:"
        echo "  macOS:  brew install fswatch"
        echo "  Linux:  sudo apt-get install inotify-tools"
        exit 1
    fi

    local WATCH_DIR_ABS
    WATCH_DIR_ABS="$(cd "$LOCAL_DIR" && pwd)"

    upload_one() {
        local full="$1"

        local full_abs
        full_abs="$(realpath "$full" 2>/dev/null || echo "$full")"

        case "$full_abs" in
            "$WATCH_DIR_ABS"/*) ;;
            *) return 0 ;;
        esac

        [[ ! -f "$full_abs" ]] && return 0

        case "$(basename "$full_abs")" in
            .DS_Store) return 0 ;;
        esac
        [[ "$full_abs" == *"/.git/"* ]] && return 0
        [[ "$full_abs" == *"/.idea/"* ]] && return 0

        local rel="${full_abs#$WATCH_DIR_ABS/}"

        local enc_rel
        enc_rel=$(url_encode "$rel")

        local dest="$REST_BASE$EXIST_COLLECTION/$enc_rel"

        echo "🔁 change detected → $rel (uploading)"
        curl -s -u "$USER:$PASS" -X PUT -T "$full_abs" "$dest" >/dev/null \
            && echo "   ✔ uploaded" \
            || echo "   ❌ upload failed for $rel"
    }

    if [[ "$watcher" == "fswatch" ]]; then
        echo "Using fswatch..."
        fswatch -r "$WATCH_DIR_ABS" | while read -r path; do
            upload_one "$path"
        done
    else
        echo "Using inotifywait..."
        inotifywait -m -r -e close_write,create "$WATCH_DIR_ABS" 2>/dev/null | \
        while read -r dir _ file; do
            upload_one "$dir/$file"
        done
    fi
}

#############################################
### ROLLBACK — restore from backup
#############################################

do_rollback() {
    local target="${1:-last}"
    local app_name="$XAR_NAME"
    local app_backup_root="$BACKUP_DIR/$app_name"

    [[ ! -d "$app_backup_root" ]] && {
        echo "No backups found for app '$app_name' in $app_backup_root"
        exit 1
    }

    mapfile -t backups < <(ls -1d "$app_backup_root"/* 2>/dev/null | sort)
    local count="${#backups[@]}"

    (( count == 0 )) && {
        echo "No backups found in $app_backup_root"
        exit 1
    }

    local chosen=""

    if [[ "$target" == "last" ]]; then
        chosen="${backups[$((count - 1))]}"
    else
        # explicit timestamp
        if [[ -d "$app_backup_root/$target" ]]; then
            chosen="$app_backup_root/$target"
        else
            echo "Requested backup timestamp '$target' not found."
            echo "Available backups:"
            for b in "${backups[@]}"; do
                echo "  - $(basename "$b")"
            done
            exit 1
        fi
    fi

    echo "⏪ Rolling back from backup:"
    echo "   $chosen"
    echo "   → collection: $EXIST_COLLECTION"

    # IMPORTANT: do NOT create another backup here, we are already restoring to a known state
    sync_dir_to_exist "$chosen"

    echo "✔ ROLLBACK COMPLETE from $chosen"
}

#############################################
### COMMAND ROUTER
#############################################

cmd="${1:-}"

case "$cmd" in
    init)       shift; do_init "$@" ;;
    edit)       shift; do_edit "$@" ;;
    export)     shift; do_export "$@" ;;
    import)     shift; do_import "$@" ;;
    watch)      shift; do_watch "$@" ;;
    build-xar)  shift; do_build_xar "$@" ;;
    backup)     shift; do_backup "$@" ;;
    rollback)   shift; do_rollback "$@" ;;
    help|--help|-h) usage ;;
    "")         usage ;;
    *)          echo "Unknown command: $cmd"; echo; usage; exit 1 ;;
esac
