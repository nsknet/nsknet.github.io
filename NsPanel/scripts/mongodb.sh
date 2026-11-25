#!/usr/bin/env bash
# mongodb.sh — MongoDB 8.3 Community Edition (Ubuntu 24.04 / 22.04, Linux Mint 21+/22+)
# Reference: https://www.mongodb.com/docs/manual/administration/install-community/
#
# Notes:
#   - MongoDB 8.3 is a minor release in the 8.0 cycle. It still uses the 8.0
#     release signing key (server-8.0.asc) but its repo path is `8.3`.
#     Override the branch with MONGODB_VERSION (e.g. 8.0).
#   - Currently only noble (24.04) and jammy (22.04) have 8.3 packages.
#     focal (20.04) gets no 8.3 — fall back to 8.0 there.
#   - Packages exist for amd64 and arm64 (arm64 needs an ARMv8.2-A CPU).
#   - Access control is ON: mongod listens on 0.0.0.0, so the install creates an
#     admin user (root role) from DB_PASSWORD through the localhost exception.

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


MONGO_PORT=27017
MONGO_VERSION="${MONGODB_VERSION:-8.3}"   # repo branch; auto-falls back to 8.0 on focal
MONGO_CONF="/etc/mongod.conf"
MONGO_CRED_DIR="/etc/mongodb"
MONGO_CRED_FILE="${MONGO_CRED_DIR}/credentials.yml"
MONGO_ADMIN_USER="admin"

# ── Detect the underlying Ubuntu LTS codename ─────────────────────────────────
# Linux Mint reports its own codename (wilma/virginia/xia/etc.) from
# `lsb_release -cs`, but /etc/os-release exposes UBUNTU_CODENAME — which is
# what MongoDB's APT repo expects (noble/jammy/focal).
_detect_ubuntu_codename() {
    local codename=""

    # 1) Prefer UBUNTU_CODENAME from /etc/os-release (set on Mint + Ubuntu derivatives).
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-}")"
    fi

    # 2) Fall back to VERSION_CODENAME (plain Ubuntu).
    if [ -z "$codename" ]; then
        codename="$(_os_codename)"
    fi

    # 3) Map Linux Mint codenames → Ubuntu base codename (in case UBUNTU_CODENAME
    #    is missing for some reason).
    case "$codename" in
        # Mint 22.x → Ubuntu 24.04 Noble
        wilma|virginia|xia|zara) codename="noble" ;;
        # Mint 21.x → Ubuntu 22.04 Jammy
        vanessa|vera|victoria) codename="jammy" ;;
        # Mint 20.x → Ubuntu 20.04 Focal
        ulyana|ulyssa|uma|una) codename="focal" ;;
    esac

    echo "$codename"
}

# Percent-encode a value for a mongodb:// URI (panel passwords may contain
# @ : % ? # and friends, which would otherwise end the userinfo part).
_mongo_uri_encode() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

_mongo_connection_string() {
    printf 'mongodb://%s:%s@127.0.0.1:%s/admin?authSource=admin' \
        "$MONGO_ADMIN_USER" "$(_mongo_uri_encode "$1")" "$MONGO_PORT"
}

# Bind to all interfaces and turn on access control in mongod.conf. Idempotent:
# rewrites existing keys in place and adds the security block only once.
_mongo_configure() {
    if [ ! -f "$MONGO_CONF" ]; then
        echo "❌  ${MONGO_CONF} not found — the mongodb-org package did not install it."
        return 1
    fi
    sed -i -E 's|^([[:space:]]*)bindIp:[[:space:]].*|\1bindIp: 0.0.0.0|' "$MONGO_CONF"
    sed -i -E "s|^([[:space:]]*)port:[[:space:]].*|\1port: ${MONGO_PORT}|" "$MONGO_CONF"

    if ! grep -qE '^security:' "$MONGO_CONF"; then
        # The package ships the section commented out (#security:).
        printf '\nsecurity:\n  authorization: enabled\n' >> "$MONGO_CONF"
    elif grep -qE '^[[:space:]]+authorization:' "$MONGO_CONF"; then
        sed -i -E 's|^([[:space:]]+)authorization:.*|\1authorization: enabled|' "$MONGO_CONF"
    else
        local tmp
        tmp="$(mktemp "${MONGO_CONF}.XXXXXX")"
        awk '{ print } /^security:/ && !done { print "  authorization: enabled"; done = 1 }' \
            "$MONGO_CONF" > "$tmp"
        cat "$tmp" > "$MONGO_CONF"   # keep the file's owner and mode
        rm -f "$tmp"
    fi
}

# Wait until mongod answers on localhost (ping needs no authentication).
_mongo_wait_ready() {
    local i
    for ((i = 0; i < 60; i++)); do
        if mongosh --quiet --norc "mongodb://127.0.0.1:${MONGO_PORT}/admin?serverSelectionTimeoutMS=2000" \
            --eval 'db.runCommand({ ping: 1 }).ok' </dev/null >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "❌  mongod did not answer on 127.0.0.1:${MONGO_PORT} within 120 s. Recent log:"
    journalctl -u mongod --no-pager -n 30 || true
    return 1
}

# Create the admin user, or set its password when it already exists.
#   - Fresh server (no users): the localhost exception allows creating the
#     first user without authenticating.
#   - Users exist: authenticate as admin with the new password (re-install with
#     the same password) or the one saved in the credentials file, then update.
# The passwords travel in a 0600 script file inside a 0700 temp dir, never in
# argv; the file is removed right after mongosh exits.
_mongo_set_admin() {
    local new_pw="$1" old_pw="" dir js out rc=0
    if [ -f "$MONGO_CRED_FILE" ]; then
        old_pw="$(sed -n 's/^admin_password: "\(.*\)"$/\1/p' "$MONGO_CRED_FILE")"
    fi
    # They are embedded in JS string literals below. The panel's validators
    # already forbid these characters; refuse rather than escape.
    case "${new_pw}${old_pw}" in
        *'"'* | *\\* | *$'\n'*)
            echo "❌  The MongoDB password may not contain double quotes, backslashes or newlines."
            return 1
            ;;
    esac

    dir="$(mktemp -d)"
    js="${dir}/set-admin.js"
    install -m 600 /dev/null "$js"
    cat > "$js" <<JS
const admin = db.getSiblingDB("admin");
const user = "${MONGO_ADMIN_USER}";
const newPw = "${new_pw}";
const candidates = ["${new_pw}", "${old_pw}"].filter((p) => p.length > 0);
const roles = [{ role: "root", db: "admin" }];

let created = false;
try {
  admin.createUser({ user: user, pwd: newPw, roles: roles });
  created = true;
} catch (e) {
  // 13 Unauthorized: users already exist, so the localhost exception is closed.
  // 51003: this user already exists.
  if (e.code !== 13 && e.code !== 51003) { throw e; }
}

if (created) {
  print("NSPANEL:created");
} else {
  let authed = false;
  for (const pw of candidates) {
    try {
      const r = admin.auth(user, pw);
      if (r && r.ok) { authed = true; break; }
    } catch (e) { /* wrong password: try the next one */ }
  }
  if (!authed) {
    throw new Error("users exist but '" + user + "' cannot log in with the new or the saved password");
  }
  admin.updateUser(user, { pwd: newPw, roles: roles });
  print("NSPANEL:updated");
}
JS

    out="$(mongosh --quiet --norc "mongodb://127.0.0.1:${MONGO_PORT}/admin" --file "$js" </dev/null 2>&1)" || rc=$?
    rm -rf "$dir"

    case "$out" in
        *"NSPANEL:created"*)
            echo "▶  Created MongoDB user '${MONGO_ADMIN_USER}' (role root on admin)."
            return 0
            ;;
        *"NSPANEL:updated"*)
            echo "▶  Updated the password of MongoDB user '${MONGO_ADMIN_USER}'."
            return 0
            ;;
    esac
    echo "❌  Could not create or update the MongoDB admin user (mongosh exit ${rc}):"
    # The script embedded the passwords: never echo a line that contains one.
    printf '%s\n' "$out" | grep -v -F -e "$new_pw" -e "${old_pw:-$new_pw}" || true
    echo "   If other users already exist, put the current password of '${MONGO_ADMIN_USER}'"
    echo "   into ${MONGO_CRED_FILE} (admin_password: \"...\") and retry."
    return 1
}

# ── MongoDB ───────────────────────────────────────────────────────────────────
install_mongodb() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing MongoDB ${MONGO_VERSION} Community Edition"
    echo "════════════════════════════════════════════════════════════"

    if [[ ! "$MONGO_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "❌  MONGODB_VERSION must look like 8.0 or 8.3 (got '${MONGO_VERSION}')."
        return 1
    fi

    # ── Platform: Ubuntu 20.04/22.04/24.04 (or a Mint based on them), amd64/arm64.
    # Mint is not "ubuntu" to _require_platform; the codename check below covers it.
    local arch
    arch="$(_os_arch)"
    if [ "$(_os_id)" = "ubuntu" ]; then
        _require_platform "MongoDB" "20.04 22.04 24.04" "amd64 arm64"
    elif [ "$arch" != "amd64" ] && [ "$arch" != "arm64" ]; then
        echo "❌  MongoDB: ${arch} is not supported (supported: amd64 arm64)."
        return 1
    fi

    # Detect base Ubuntu LTS codename (works for Ubuntu and Linux Mint).
    local codename
    codename="$(_detect_ubuntu_codename)"
    echo "▶  Detected Ubuntu base codename: ${codename:-<unknown>}"

    # Pick the right MongoDB branch for this Ubuntu release.
    # 8.3 is only published for noble + jammy; focal still needs 8.0.
    local branch="${MONGO_VERSION}"
    case "$codename" in
        noble|jammy) ;;
        focal)
            echo "⚠  MongoDB ${MONGO_VERSION} is not published for focal (20.04). Falling back to 8.0."
            branch="8.0"
            ;;
        *)
            echo "❌  Unsupported Ubuntu base '${codename:-unknown}': MongoDB publishes packages"
            echo "    for jammy (22.04) and noble (24.04) only (focal gets 8.0)."
            return 1
            ;;
    esac

    # Prerequisites
    apt-get update -q
    apt-get install -y gnupg curl

    # Import the MongoDB GPG signing key. MongoDB 8.x minors (including 8.3) use
    # the 8.0 release signing key; older branches have their own.
    local key_ver="$branch"
    case "$branch" in 8.*) key_ver="8.0" ;; esac
    local keyring="/usr/share/keyrings/mongodb-server-${key_ver}.gpg"
    echo "▶  Importing MongoDB ${key_ver} GPG key..."
    curl -fsSL --max-time 60 --retry 3 "https://pgp.mongodb.com/server-${key_ver}.asc" \
        | gpg --batch --yes --dearmor -o "$keyring"

    # Remove any stale MongoDB list files from previous branches so apt doesn't
    # see duplicate sources (e.g. 8.0 → 8.3 upgrade).
    rm -f /etc/apt/sources.list.d/mongodb-org-*.list

    echo "▶  Adding MongoDB ${branch} APT repository for ${codename} (${arch})..."
    echo "deb [ arch=${arch} signed-by=${keyring} ] \
https://repo.mongodb.org/apt/ubuntu ${codename}/mongodb-org/${branch} multiverse" \
        > "/etc/apt/sources.list.d/mongodb-org-${branch}.list"

    apt-get update -q
    apt-get install -y mongodb-org

    # ── Password: use the one supplied by the panel, else generate one ───────
    local db_password
    db_password="${DB_PASSWORD:-$(gen_password)}"

    # ── Bind to all interfaces so the LAN subnets allowed by UFW can connect,
    # with access control on: nobody gets in without the admin login.
    echo "▶  Configuring ${MONGO_CONF} (bindIp 0.0.0.0, port ${MONGO_PORT}, authorization enabled)..."
    _mongo_configure

    # ── Service registration (same pattern as elasticsearch.sh) ───────────────
    # Use /bin/systemctl explicitly for daemon-reload in case PATH is stripped.
    /bin/systemctl daemon-reload
    systemctl enable mongod.service
    systemctl restart mongod.service
    _register_panel_service mongod

    echo "▶  Waiting for mongod..."
    _mongo_wait_ready

    # ── Admin user ────────────────────────────────────────────────────────────
    _mongo_set_admin "$db_password"

    # ── Save credentials ──────────────────────────────────────────────────────
    echo "▶  Saving credentials to ${MONGO_CRED_FILE}..."
    install -d -m 700 "$MONGO_CRED_DIR"
    # Create it 0600 first: a later chmod leaves a window where the file is world-readable.
    install -m 600 /dev/null "$MONGO_CRED_FILE"
    cat > "$MONGO_CRED_FILE" <<CRED
# MongoDB credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: mongodb
version: "${branch}"

admin_user: "${MONGO_ADMIN_USER}"
admin_password: "${db_password}"
auth_db: "admin"

port: ${MONGO_PORT}
host: "127.0.0.1"
connection_string: "$(_mongo_connection_string "$db_password")"

notes: "Bound to 0.0.0.0 with authorization enabled; UFW restricts access."
CRED
    chmod 600 "$MONGO_CRED_FILE"

    # Firewall: allow only the chosen subnets.
    _ufw_allow_port "${MONGO_PORT}" "MongoDB"

    systemctl status mongod --no-pager || true

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  MongoDB ${branch} installed."
    echo "   Port     : ${MONGO_PORT}  (bound to 0.0.0.0, authorization enabled)"
    echo "   User     : ${MONGO_ADMIN_USER}  (role root, auth db admin)"
    echo "   Password : saved in ${MONGO_CRED_FILE} (mode 600)"
    echo "   Data     : /var/lib/mongodb"
    echo "   Logs     : /var/log/mongodb/mongod.log"
    echo "   Conf     : ${MONGO_CONF}"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Test     : mongosh \"mongodb://${MONGO_ADMIN_USER}@127.0.0.1:${MONGO_PORT}/admin\"   (prompts for the password)"
    echo "════════════════════════════════════════════════════════════"
}

# Change the admin password. New password comes from DB_PASSWORD.
set_mongodb_password() {
    local db_password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating MongoDB password for '${MONGO_ADMIN_USER}'..."
    _mongo_set_admin "$db_password"

    if [ -f "$MONGO_CRED_FILE" ]; then
        echo "▶  Updating ${MONGO_CRED_FILE}..."
        cred_set "$MONGO_CRED_FILE" admin_password "${db_password}"
        cred_set "$MONGO_CRED_FILE" connection_string "$(_mongo_connection_string "$db_password")"
    fi
    echo "✔  MongoDB password updated."
}

uninstall_mongodb() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing MongoDB"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now mongod 2>/dev/null || true
    apt-get purge -y mongodb-org "mongodb-org-*" 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/mongodb /var/log/mongodb "$MONGO_CRED_DIR"
    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    rm -f /usr/share/keyrings/mongodb-server-*.gpg
    _unregister_panel_service mongod
    echo "✔  MongoDB removed (data in /var/lib/mongodb deleted)."
}
