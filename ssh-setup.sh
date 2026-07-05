#!/bin/bash

# SSH Key Generator, Rotator, and Config Manager
# Setup:  generate a new SSH key, copy it to a server, and update ~/.ssh/config.
# Rotate: replace the key of an existing ~/.ssh/config entry with a fresh one.
# With --local-user, run as root but install the key/config for another local
# account (e.g. sudo ssh-setup.sh --host x --local-user skint007): the script
# re-execs itself as that user, so ssh and every file it writes act as them.

set -euo pipefail

# Restrict permissions on any files/dirs this script creates (keys, config, temp)
umask 077

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Single source of truth for the date tag embedded in key comments (valid for
# grep -E, sed -E, and awk dynamic regexes) and for interpreting "Host" lines
# and config values in awk — every reader/writer below shares these so the
# formats can't drift apart.
DATE_TAG_RE='\((created|rotated) [0-9]{4}-[0-9]{2}-[0-9]{2}\)'
AWK_HOST_FUNCS='
    function host_line_matches(host,   i) {
        for (i = 2; i <= NF; i++) if ($i == host) return 1
        return 0
    }
    function unquote(s) { gsub(/^"|"$/, "", s); return s }
'

# Function to show usage
usage() {
    cat << EOF
Usage: $0 --host <hostname> [OPTIONS]          # set up a new key
       $0 --rotate --alias <name> [OPTIONS]    # rotate an existing key
       $0 --check-age [--max-age <days>]       # find keys due for rotation

Generate an SSH key, copy it to a server, and update ~/.ssh/config.
With --rotate, replace the key of an existing config entry in place.
With --check-age, list managed keys by age and offer to rotate old ones.

OPTIONS:
    -h, --host          Target hostname or IP address (required for setup)
    -u, --user          Username for SSH connection (default: the local user)
    --local-user        Local account to install the key and SSH config for
                        (default: the user running the script). Run as root to
                        install for another user, e.g. --local-user skint007;
                        the script re-execs itself as that user.
    -p, --port          SSH port (default: 22)
    -n, --name          Key name identifier (default: hostname)
    -c, --comment       Comment for the SSH key (default: user@hostname)
    -t, --type          Key type: ed25519, rsa, ecdsa (default: ed25519)
    -b, --bits          Key bits for RSA keys (default: 4096)
    --alias             SSH config Host alias (default: hostname)
    --rotate            Rotate the key of an existing entry (selected by --alias
                        or --host): generate a fresh key matching the old one,
                        install it, verify it, then remove the old key from the
                        server. Reuses the entry's HostName/User/Port.
    --check-age         List every key referenced by ~/.ssh/config with its age
                        (from the date tag in the key comment, or file mtime)
                        and offer to rotate any due for rotation
    --max-age           Days before a key counts as due for rotation
                        (default: 90; used with --check-age)
    --help              Show this help message

Note: -h means --host, not help. Use --help for this message.

EXAMPLES:
    $0 --host example.com --user myuser
    $0 -h 192.168.1.100 -u admin -p 2222 -n homeserver
    $0 --host github.com --user git --alias github --name github
    $0 --rotate --alias homeserver
    $0 --check-age --max-age 180
    sudo $0 --host example.com --local-user skint007

EOF
}

# Return success if a "Host" line in file $2 lists alias $1 as one of its
# patterns. Exact token comparison keeps regex/glob aliases (e.g. *.example.com)
# safe and matches multi-alias "Host a b c" lines correctly.
host_exists() {
    awk -v host="$1" "$AWK_HOST_FUNCS"'
        /^[[:space:]]*[Hh]ost[[:space:]]/ { if (host_line_matches(host)) { found = 1; exit } }
        END { exit found ? 0 : 1 }
    ' "$2"
}

# Print the value of SSH config keyword $2 from the Host block whose alias is $1
# (read from $SSH_CONFIG). Handles the space-separated form this tool writes;
# surrounding double quotes (legal ssh_config syntax) are stripped.
config_get() {
    awk -v host="$1" -v key="$2" "$AWK_HOST_FUNCS"'
        /^[[:space:]]*[Hh]ost[[:space:]]/ { inblk = host_line_matches(host); next }
        inblk && tolower($1) == tolower(key) {
            $1 = ""; sub(/^[[:space:]]+/, ""); print unquote($0); exit
        }
    ' "$SSH_CONFIG"
}

# Print the epoch time key $1 was created or last rotated: prefers the
# "(created YYYY-MM-DD)"/"(rotated YYYY-MM-DD)" tag this script embeds in the
# key comment, falling back to the key file's mtime — private key first, then
# the .pub (rotation rewrites both, so mtime tracks rotation even for untagged
# keys). Fails only if neither file exists.
key_stamp_epoch() {
    local key="$1" d="" epoch=""
    if [[ -f "$key.pub" ]]; then
        d=$(grep -oE "$DATE_TAG_RE" "$key.pub" \
            | tail -n1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}') || true
        # A tag that is not a real calendar date (e.g. 2026-13-45) falls
        # through to the mtime fallback instead of erroring out.
        if [[ -n "$d" ]] && epoch=$(date -d "$d" +%s 2>/dev/null); then
            echo "$epoch"
            return 0
        fi
    fi
    if [[ -f "$key" ]]; then
        stat -c %Y "$key"
    elif [[ -f "$key.pub" ]]; then
        stat -c %Y "$key.pub"
    else
        return 1
    fi
}

# Strip any "(created ...)"/"(rotated ...)" date tag from a key comment, so a
# fresh tag can be appended without stacking one per rotation.
strip_date_tag() {
    sed -E "s/ *${DATE_TAG_RE}//g" <<< "$1"
}

# Show the age of every key referenced by a Host entry in ~/.ssh/config and
# offer to rotate each one older than MAX_AGE_DAYS.
do_check_age() {
    local now alias file key epoch age status color stamp entries
    local due=()

    if [[ ! -f "$SSH_CONFIG" ]]; then
        print_error "No SSH config found at $SSH_CONFIG."
        return 1
    fi

    # "alias<TAB>identityfile" per Host block: the first non-glob alias
    # represents the block (so "Host *.x.com myhost" is still listed), the
    # first IdentityFile wins, and quoted paths are unquoted. Collected up
    # front so an awk failure is a hard error, not a silently empty report.
    if ! entries=$(awk "$AWK_HOST_FUNCS"'
        /^[[:space:]]*[Hh]ost[[:space:]]/ {
            alias = ""; idf = 0
            for (i = 2; i <= NF; i++) if ($i !~ /[*?]/) { alias = $i; break }
            next
        }
        alias != "" && !idf && tolower($1) == "identityfile" {
            idf = 1
            $1 = ""; sub(/^[[:space:]]+/, "")
            print alias "\t" unquote($0)
        }
    ' "$SSH_CONFIG"); then
        print_error "Could not parse $SSH_CONFIG."
        return 1
    fi
    if [[ -z "$entries" ]]; then
        print_info "No Host entries with an IdentityFile found in $SSH_CONFIG."
        return 0
    fi

    now=$(date +%s)
    print_info "Checking key ages (rotation due after $MAX_AGE_DAYS days):"
    echo
    printf '  %-20s %-12s %6s  %-14s %s\n' "HOST" "CREATED" "AGE" "STATUS" "KEY"

    while IFS=$'\t' read -r alias file; do
        key="${file/#\~/$HOME}"
        if epoch=$(key_stamp_epoch "$key"); then
            age=$(( (now - epoch) / 86400 ))
            stamp=$(date -d "@$epoch" +%Y-%m-%d)
            if (( age < 0 )); then
                # A tag in the future (typo, clock skew) would read as a huge
                # negative age and count as "ok" forever — flag it instead.
                age=0
                color="$YELLOW"; status="future date?"
            elif (( age >= MAX_AGE_DAYS )); then
                color="$RED"; status="rotation due"
                due+=("$alias")
            else
                color="$GREEN"; status="ok"
            fi
            printf "  %-20s %-12s %6s  ${color}%-14s${NC} %s\n" \
                "$alias" "$stamp" "${age}d" "$status" "$key"
        else
            printf "  %-20s %-12s %6s  ${YELLOW}%-14s${NC} %s\n" \
                "$alias" "-" "-" "key missing" "$key"
        fi
    done <<< "$entries"

    echo
    if (( ${#due[@]} == 0 )); then
        print_success "No keys are due for rotation."
        return 0
    fi

    print_warning "${#due[@]} key(s) due for rotation."
    for alias in "${due[@]}"; do
        read -p "Rotate '$alias' now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            do_rotate "$alias" || print_error "Rotation of '$alias' failed; continuing with the rest."
            echo
        fi
    done
    return 0
}

# Timestamped backup of the SSH config, taken only immediately before a write.
# At most one backup per run, so it always captures the pre-run state (a
# --check-age run rotating several keys doesn't leave a trail of backups).
CONFIG_BACKED_UP=false
backup_config() {
    local backup
    [[ "$CONFIG_BACKED_UP" == true ]] && return 0
    CONFIG_BACKED_UP=true
    backup="$SSH_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$SSH_CONFIG" "$backup"
    print_info "Backup of SSH config created: $backup"
}

# Refresh the date tag in the comment line heading the Host block for alias $1,
# so the config itself shows when the key was last rotated. Comment-only edit:
# entries without a heading comment are left untouched.
CONFIG_COMMENT_TAGGED=false
update_config_comment() {
    local target="$1" tmp
    tmp=$(mktemp)
    DATE_TAG_RE="$DATE_TAG_RE" awk -v host="$target" -v date="$(date +%Y-%m-%d)" "$AWK_HOST_FUNCS"'
        { lines[NR] = $0 }
        !done && /^[[:space:]]*[Hh]ost[[:space:]]/ {
            if (host_line_matches(host) && NR > 1 && lines[NR-1] ~ /^[[:space:]]*#/) {
                gsub(" *" ENVIRON["DATE_TAG_RE"], "", lines[NR-1])
                lines[NR-1] = lines[NR-1] " (rotated " date ")"
                done = 1
            }
        }
        END { for (k = 1; k <= NR; k++) print lines[k] }
    ' "$SSH_CONFIG" > "$tmp" || { rm -f "$tmp"; return 0; }
    if ! cmp -s "$tmp" "$SSH_CONFIG"; then
        backup_config
        mv "$tmp" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        CONFIG_COMMENT_TAGGED=true
        print_info "Config comment updated with the rotation date."
    else
        rm -f "$tmp"
    fi
}

# Rotate the key for an existing config entry, replacing it in place. Returns
# non-zero (without touching the old key) if anything before the swap fails, so
# a failed rotation can never lock you out.
do_rotate() {
    local target hostname user port old_key old_pub old_blob old_comment
    local key_type bits new_key new_comment installed old_deleted remote_rm

    # Per-rotation flag, reset here so a --check-age batch can't carry a stale
    # "tagged" state from an earlier rotation into this one's summary.
    CONFIG_COMMENT_TAGGED=false

    target="${1:-${ALIAS:-$HOST}}"
    if [[ -z "$target" ]]; then
        print_error "Rotate needs an entry to act on. Use --alias <name> (or --host)."
        usage
        return 1
    fi

    if [[ ! -f "$SSH_CONFIG" ]] || ! host_exists "$target" "$SSH_CONFIG"; then
        print_error "No SSH config entry found for '$target'. Run setup for it first."
        return 1
    fi

    hostname=$(config_get "$target" HostName); hostname="${hostname:-$target}"
    user=$(config_get "$target" User);         user="${user:-$CURRENT_USER}"
    port=$(config_get "$target" Port);         port="${port:-22}"
    old_key=$(config_get "$target" IdentityFile)
    old_key="${old_key/#\~/$HOME}"

    if [[ -z "$old_key" ]]; then
        print_error "Entry '$target' has no IdentityFile; cannot determine the key to rotate."
        return 1
    fi

    print_info "Rotating SSH key for '$target' ($user@$hostname:$port)"
    echo "  Current key: $old_key"
    echo

    # Recover the old public key (derive it from the private key if .pub is gone)
    old_pub="$old_key.pub"
    if [[ ! -f "$old_pub" && -f "$old_key" ]]; then
        print_info "Public key missing; deriving it from the private key."
        ssh-keygen -y -f "$old_key" > "$old_pub" 2>/dev/null || true
        [[ -f "$old_pub" ]] && chmod 644 "$old_pub"
    fi

    if [[ -f "$old_pub" ]]; then
        old_blob=$(awk '{print $2}' "$old_pub")
        old_comment=$(cut -d' ' -f3- "$old_pub")
    else
        old_blob=""
        old_comment=""
        print_warning "Old public key unavailable; it cannot be auto-removed from the server."
    fi

    # Match the new key's type/size to the old one
    if [[ -f "$old_pub" ]]; then
        case "$(awk '{print $1}' "$old_pub")" in
            ssh-ed25519)               key_type="ed25519" ;;
            ssh-rsa)                   key_type="rsa" ;;
            ecdsa-sha2-*)              key_type="ecdsa" ;;
            sk-ssh-ed25519*|sk-ecdsa*) print_error "FIDO/hardware-backed keys can't be rotated by this script."; return 1 ;;
            *)                         key_type="ed25519" ;;
        esac
        bits=$(ssh-keygen -l -f "$old_pub" 2>/dev/null | awk '{print $1}') || bits=""
    else
        case "$old_key" in
            *id_rsa_*)   key_type="rsa";   bits=4096 ;;
            *id_ecdsa_*) key_type="ecdsa"; bits=521 ;;
            *)           key_type="ed25519"; bits="" ;;
        esac
    fi

    # Replace any existing date tag so repeat rotations don't stack them
    old_comment=$(strip_date_tag "$old_comment")
    new_comment="${old_comment:-$target} (rotated $(date +%Y-%m-%d))"
    new_key="$old_key.rotated.$$"
    rm -f "$new_key" "$new_key.pub"

    print_info "Generating new $key_type key..."
    case "$key_type" in
        ed25519) ssh-keygen -t ed25519 -C "$new_comment" -f "$new_key" -N "" ;;
        rsa)     ssh-keygen -t rsa -b "${bits:-4096}" -C "$new_comment" -f "$new_key" -N "" ;;
        ecdsa)   ssh-keygen -t ecdsa -b "${bits:-521}" -C "$new_comment" -f "$new_key" -N "" ;;
    esac
    if [[ ! -f "$new_key" ]]; then
        print_error "Failed to generate the new key."
        return 1
    fi
    chmod 600 "$new_key"; chmod 644 "$new_key.pub"

    # Install the new public key, preferring the old key for non-interactive auth
    print_info "Installing new public key on $user@$hostname:$port..."
    installed=false
    if [[ -f "$old_key" ]] && ssh -i "$old_key" -p "$port" \
            -o IdentitiesOnly=yes -o BatchMode=yes "$user@$hostname" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
            < "$new_key.pub"; then
        installed=true
    elif command -v ssh-copy-id >/dev/null 2>&1 && \
            ssh-copy-id -i "$new_key.pub" -p "$port" "$user@$hostname"; then
        installed=true
    elif ssh -p "$port" "$user@$hostname" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
            < "$new_key.pub"; then
        installed=true
    fi
    if [[ "$installed" != true ]]; then
        print_error "Could not install the new key on the server. Aborting; nothing changed."
        rm -f "$new_key" "$new_key.pub"
        return 1
    fi
    print_success "New public key installed."

    # Verify the new key BEFORE removing the old one, so a failure can't lock us out
    print_info "Verifying the new key works..."
    # -n: don't let ssh consume our stdin — a --check-age batch reads its
    # "Rotate?" answers from the same terminal after this call returns.
    if ! ssh -n -i "$new_key" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
            -o ConnectTimeout=10 "$user@$hostname" "true" >/dev/null 2>&1; then
        print_error "The new key did not authenticate. Aborting rotation; the old key is untouched."
        print_warning "An unused public key may have been added to the server; remove it manually if desired."
        rm -f "$new_key" "$new_key.pub"
        return 1
    fi
    print_success "New key verified."

    # New key is verified working, so delete the old local key and move the new
    # one into its place. The IdentityFile path is unchanged: no config edit.
    old_deleted=false
    if [[ -f "$old_key" ]]; then
        rm -f "$old_key" "$old_pub"
        old_deleted=true
        print_info "Old local key deleted (new key verified)."
    fi
    mv "$new_key" "$old_key"
    mv "$new_key.pub" "$old_pub"
    chmod 600 "$old_key"; chmod 644 "$old_pub"

    # Keep the config's comment header in sync with the key's rotation date
    update_config_comment "$target"

    # Remove the old public key from the server, authenticating with the new key.
    # Only overwrites authorized_keys when the filtered result is non-empty.
    if [[ -n "$old_blob" ]]; then
        print_info "Removing the old key from the server's authorized_keys..."
        remote_rm="f=\$HOME/.ssh/authorized_keys; if [ -f \"\$f\" ]; then grep -vF '$old_blob' \"\$f\" > \"\$f.tmp\" 2>/dev/null || true; if [ -s \"\$f.tmp\" ]; then mv \"\$f.tmp\" \"\$f\"; chmod 600 \"\$f\"; else rm -f \"\$f.tmp\"; fi; fi"
        if ssh -n -i "$old_key" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
                "$user@$hostname" "$remote_rm"; then
            print_success "Old key removed from the server."
        else
            print_warning "Could not remove the old key automatically. On the server, delete the"
            print_warning "authorized_keys line containing this key:"
            echo "  $old_blob"
        fi
    fi

    echo
    print_success "Key rotation completed!"
    print_info "Summary:"
    echo "  ✓ New $key_type key generated and installed: $old_key"
    echo "  ✓ New key verified working"
    [[ "$old_deleted" == true ]] && echo "  ✓ Old key deleted locally"
    [[ "$CONFIG_COMMENT_TAGGED" == true ]] && echo "  ✓ Config comment tagged (rotated $(date +%Y-%m-%d))"
    [[ -n "$old_blob" ]] && echo "  ✓ Old key removed from server (or manual instructions printed above)"
    echo
    print_info "Connect as usual:"
    echo "  ssh $target"
    return 0
}

# Default values (REMOTE_USER defaults to the local user once resolved below)
REMOTE_USER=""
REMOTE_USER_SET=false
PORT=22
KEY_TYPE="ed25519"
KEY_BITS=4096
HOST=""
KEY_NAME=""
COMMENT=""
ALIAS=""
ROTATE=false
CHECK_AGE=false
MAX_AGE_DAYS=90
LOCAL_USER=""

# Keep the original arguments so we can re-exec as the target user unchanged
# (minus --local-user) when installing on someone else's behalf.
ORIG_ARGS=("$@")

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            HOST="$2"
            shift 2
            ;;
        -u|--user)
            REMOTE_USER="$2"
            REMOTE_USER_SET=true
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -n|--name)
            KEY_NAME="$2"
            shift 2
            ;;
        -c|--comment)
            COMMENT="$2"
            shift 2
            ;;
        -t|--type)
            KEY_TYPE="$2"
            shift 2
            ;;
        -b|--bits)
            KEY_BITS="$2"
            shift 2
            ;;
        --alias)
            ALIAS="$2"
            shift 2
            ;;
        --local-user)
            LOCAL_USER="$2"
            shift 2
            ;;
        --rotate)
            ROTATE=true
            shift
            ;;
        --check-age)
            CHECK_AGE=true
            shift
            ;;
        --max-age)
            if [[ $# -lt 2 ]]; then
                print_error "--max-age requires a value (number of days)."
                exit 1
            fi
            MAX_AGE_DAYS="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

CURRENT_USER=$(id -un)
LOCAL_USER="${LOCAL_USER:-$CURRENT_USER}"

# Installing for a different local account: re-exec the whole script as that
# user. From there ssh natively resolves their ~/.ssh/config, known_hosts,
# identities and agent, and every file created is already owned by them — no
# chown dance and no config/known_hosts path juggling. Requires root.
if [[ "$LOCAL_USER" != "$CURRENT_USER" ]]; then
    if [[ $EUID -ne 0 ]]; then
        print_error "Installing for another user ($LOCAL_USER) requires running as root."
        exit 1
    fi
    if ! id "$LOCAL_USER" >/dev/null 2>&1; then
        print_error "No such local user: '$LOCAL_USER'"
        exit 1
    fi
    if ! command -v runuser >/dev/null 2>&1; then
        print_error "runuser (util-linux) is required to install for another user but was not found."
        exit 1
    fi

    # Forward the original args, dropping --local-user and its value.
    FORWARD_ARGS=()
    skip_next=false
    for a in "${ORIG_ARGS[@]}"; do
        if [[ "$skip_next" == true ]]; then skip_next=false; continue; fi
        if [[ "$a" == "--local-user" ]]; then skip_next=true; continue; fi
        FORWARD_ARGS+=("$a")
    done

    # Resolve to an absolute path: $0 is already absolute when run via PATH or a
    # shebang; make it absolute for ./script or bare relative invocations too.
    SELF="$0"
    [[ "$SELF" == /* ]] || SELF="$(pwd)/$SELF"

    print_info "Setting up SSH for '$LOCAL_USER' — re-running as that user..."
    exec runuser -u "$LOCAL_USER" -- bash "$SELF" "${FORWARD_ARGS[@]}"
fi

# From here on we are running as the account the key/config are installed for,
# so plain $HOME is that account's home — exactly where ssh will look later.
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"

# The remote username defaults to the local account. An explicitly-empty
# --user "" is a misconfiguration (e.g. an unset automation variable), so fail
# loudly instead of silently substituting a default.
if [[ "$REMOTE_USER_SET" == true && -z "$REMOTE_USER" ]]; then
    print_error "The --user value is empty. Provide a username, or omit --user to default to '$CURRENT_USER'."
    exit 1
fi
REMOTE_USER="${REMOTE_USER:-$CURRENT_USER}"

# Age-check mode: report key ages and offer rotations, then exit.
if [[ "$CHECK_AGE" == true ]]; then
    if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || (( MAX_AGE_DAYS == 0 )); then
        print_error "--max-age must be a positive number of days (got '$MAX_AGE_DAYS')."
        exit 1
    fi
    do_check_age
    exit $?
fi

# Rotation mode: replace the key of an existing entry in place (reusing its
# HostName/User/Port/IdentityFile from ~/.ssh/config), then exit.
if [[ "$ROTATE" == true ]]; then
    do_rotate
    exit $?
fi

# Validate required parameters
if [[ -z "$HOST" ]]; then
    print_error "Host is required. Use -h or --host to specify the target hostname."
    usage
    exit 1
fi

# Set defaults based on host if not provided
if [[ -z "$KEY_NAME" ]]; then
    KEY_NAME="$HOST"
fi

if [[ -z "$COMMENT" ]]; then
    # Try different methods to get hostname
    if command -v hostname >/dev/null 2>&1; then
        LOCAL_HOST=$(hostname)
    elif [[ -f /etc/hostname ]]; then
        LOCAL_HOST=$(cat /etc/hostname)
    elif command -v uname >/dev/null 2>&1; then
        LOCAL_HOST=$(uname -n)
    else
        LOCAL_HOST="localhost"
    fi
    COMMENT="${CURRENT_USER}@${LOCAL_HOST}_to_${HOST}"
fi

# Tag the comment with the creation date so --check-age can compute key age
# later without any external state.
if ! grep -qE "$DATE_TAG_RE" <<< "$COMMENT"; then
    COMMENT="$COMMENT (created $(date +%Y-%m-%d))"
fi

if [[ -z "$ALIAS" ]]; then
    ALIAS="$HOST"
fi

# Validate key type
case $KEY_TYPE in
    ed25519|rsa|ecdsa)
        ;;
    *)
        print_error "Invalid key type: $KEY_TYPE. Supported types: ed25519, rsa, ecdsa"
        exit 1
        ;;
esac

# Set key filename based on type and name
if [[ "$KEY_TYPE" == "ed25519" ]]; then
    KEY_FILE="$SSH_DIR/id_ed25519_$KEY_NAME"
elif [[ "$KEY_TYPE" == "rsa" ]]; then
    KEY_FILE="$SSH_DIR/id_rsa_$KEY_NAME"
else
    KEY_FILE="$SSH_DIR/id_ecdsa_$KEY_NAME"
fi

# Display configuration
print_info "SSH Key Generation Configuration:"
echo "  Host: $HOST"
echo "  User: $REMOTE_USER"
echo "  Port: $PORT"
echo "  Key Type: $KEY_TYPE"
echo "  Key Name: $KEY_NAME"
echo "  Key File: $KEY_FILE"
echo "  Comment: $COMMENT"
echo "  SSH Config Alias: $ALIAS"
echo

# Check if key already exists
if [[ -f "$KEY_FILE" ]]; then
    print_warning "Key file $KEY_FILE already exists."
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Exiting without generating new key."
        exit 0
    fi
    rm -f "$KEY_FILE" "$KEY_FILE.pub"
fi

# Create .ssh directory if it doesn't exist. mkdir/chmod are idempotent, so no
# guard is needed; running as the target user keeps ownership correct.
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate SSH key
print_info "Generating $KEY_TYPE SSH key..."
if [[ "$KEY_TYPE" == "ed25519" ]]; then
    ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_FILE" -N ""
elif [[ "$KEY_TYPE" == "rsa" ]]; then
    ssh-keygen -t rsa -b "$KEY_BITS" -C "$COMMENT" -f "$KEY_FILE" -N ""
else # ecdsa
    ssh-keygen -t ecdsa -b 521 -C "$COMMENT" -f "$KEY_FILE" -N ""
fi

if [[ ! -f "$KEY_FILE" ]]; then
    print_error "Failed to generate SSH key"
    exit 1
fi

print_success "SSH key generated successfully!"

# Set proper permissions
chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"

# Copy key to server
print_info "Copying public key to $REMOTE_USER@$HOST:$PORT..."

# Manual fallback: append the public key to the server's authorized_keys.
# Reads the key via stdin redirection (no useless cat) and returns ssh's exit status.
copy_key_manual() {
    ssh -p "$PORT" "$REMOTE_USER@$HOST" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
        < "$KEY_FILE.pub"
}

# Try ssh-copy-id first, fall back to the manual method if it is missing or fails.
# Each command is the condition of an if, so set -e does not abort before we react.
if command -v ssh-copy-id >/dev/null 2>&1; then
    if ssh-copy-id -i "$KEY_FILE.pub" -p "$PORT" "$REMOTE_USER@$HOST"; then
        print_success "Public key copied successfully using ssh-copy-id"
    else
        print_warning "ssh-copy-id failed, trying manual method..."
        if copy_key_manual; then
            print_success "Public key copied successfully using manual method"
        else
            print_error "Failed to copy public key to server"
            exit 1
        fi
    fi
else
    print_info "ssh-copy-id not found, using manual method..."
    if copy_key_manual; then
        print_success "Public key copied successfully"
    else
        print_error "Failed to copy public key to server"
        exit 1
    fi
fi

# Update ~/.ssh/config
print_info "Updating SSH config..."

TEMP_CONFIG=$(mktemp)

# Create SSH config entry
CONFIG_ENTRY="

# $COMMENT
Host $ALIAS
    HostName $HOST
    User $REMOTE_USER
    Port $PORT
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
"

# Check if config file exists and if this host is already configured
if [[ -f "$SSH_CONFIG" ]]; then
    if host_exists "$ALIAS" "$SSH_CONFIG"; then
        print_warning "Host '$ALIAS' already exists in SSH config."
        read -p "Do you want to replace it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            backup_config
            # Remove the existing block, including the comment/blank lines that head it,
            # then append the new entry. Buffered comment/blank lines are dropped when
            # they belong to the removed block and flushed (kept) otherwise.
            awk -v host="$ALIAS" "$AWK_HOST_FUNCS"'
                function flush() { printf "%s", buf; buf = "" }
                /^[[:space:]]*#/ { if (skip) next; buf = buf $0 "\n"; next }
                /^[[:space:]]*$/ { if (skip) { skip = 0; buf = ""; next } buf = buf $0 "\n"; next }
                /^[[:space:]]*[Hh]ost[[:space:]]/ {
                    if (host_line_matches(host)) { skip = 1; buf = ""; next }
                    flush(); print; next
                }
                { if (skip) next; flush(); print }
                END { if (!skip) flush() }
            ' "$SSH_CONFIG" > "$TEMP_CONFIG"
            echo "$CONFIG_ENTRY" >> "$TEMP_CONFIG"
            mv "$TEMP_CONFIG" "$SSH_CONFIG"
            print_success "SSH config updated (replaced existing entry)"
        else
            print_info "SSH config left unchanged"
        fi
    else
        # Add new entry
        backup_config
        cp "$SSH_CONFIG" "$TEMP_CONFIG"
        echo "$CONFIG_ENTRY" >> "$TEMP_CONFIG"
        mv "$TEMP_CONFIG" "$SSH_CONFIG"
        print_success "SSH config updated (new entry added)"
    fi
else
    # Create new config file
    echo "$CONFIG_ENTRY" > "$SSH_CONFIG"
    print_success "SSH config created"
fi

# Set proper permissions on config file
chmod 600 "$SSH_CONFIG"

# Test the connection
print_info "Testing SSH connection..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$ALIAS" "echo 'SSH connection successful'" 2>/dev/null; then
    print_success "SSH connection test passed!"
else
    print_warning "SSH connection test failed. This might be normal if the server doesn't allow non-interactive connections."
fi

# Display summary
print_success "Setup completed successfully!"
echo
print_info "Summary:"
echo "  ✓ SSH key generated: $KEY_FILE"
echo "  ✓ Public key copied to server"
echo "  ✓ SSH config updated"
echo
print_info "You can now connect using:"
echo "  ssh $ALIAS"
echo
print_info "Or test the connection:"
echo "  ssh -v $ALIAS"

# Display the generated config entry
print_info "SSH Config entry added:"
echo "$CONFIG_ENTRY"

rm -f "$TEMP_CONFIG" 2>/dev/null || true
