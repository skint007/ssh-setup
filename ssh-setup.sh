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

# Every ssh this script runs to provision, verify, or clean up a key must reach
# the *intended* host directly. A "Host *" block with ControlMaster/ControlPersist
# leaves a persisted master socket around, and a later ssh to the same name would
# silently ride that master — tunnelling the key copy or the verify to whatever
# host the old connection points at. ControlPath=none forces a fresh connection.
SSH_NOMUX=(-o ControlPath=none)

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
       $0 --remove-key --host <name> [OPTIONS] # remove a key from a server
       $0 --bootstrap <machine> --host <name>  # set up ANOTHER machine's access

Generate an SSH key, copy it to a server, and update ~/.ssh/config.
With --rotate, replace the key of an existing config entry in place.
With --check-age, list managed keys by age and offer to rotate old ones.
With --remove-key, delete a public key from a server's authorized_keys.
With --bootstrap, give a different machine access to servers this one can reach.

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
                        server. Reuses the entry's HostName/User/Port. GitHub
                        hosts are rotated via the gh CLI (needs gh with the
                        admin:public_key scope) instead of authorized_keys.
    --check-age         List every key referenced by ~/.ssh/config with its age
                        (from the date tag in the key comment, or file mtime)
                        and offer to rotate any due for rotation
    --max-age           Days before a key counts as due for rotation
                        (default: 90; used with --check-age)
    --remove-key        Remove a public key from a server's authorized_keys (the
                        inverse of installing one). Target with --host or --alias
                        (an --alias reuses the entry's HostName/User/Port and
                        authenticates with its key). Refuses to remove the last
                        remaining key so you can't lock yourself out.
    --pubkey            Public key file to remove (with --remove-key).
                        Default: ~/.ssh/id_ed25519.pub
    --key               Literal public key string to remove instead of a file,
                        e.g. --key 'ssh-ed25519 AAAA...' (with --remove-key)
    --bootstrap         Machine to set up access FOR, using this machine's
                        existing access to the servers. The keypair is generated
                        on that machine (no private key is ever copied), the
                        public key is installed on each server from here, the
                        Host entry is written on that machine, and the machine
                        itself verifies the connection. Target servers with
                        --host and/or --hosts-file.
    --hosts-file        File listing servers to bootstrap, one "[user@]host[:port]"
                        per line; blank lines and "#" comments are ignored
    --domain            Domain suffix appended to any bare (dotless) server name,
                        e.g. --domain tail1234.ts.net
    --help              Show this help message

Note: -h means --host, not help. Use --help for this message.

EXAMPLES:
    $0 --host example.com --user myuser
    $0 -h 192.168.1.100 -u admin -p 2222 -n homeserver
    $0 --host github.com --user git --alias github --name github
    $0 --rotate --alias homeserver
    $0 --check-age --max-age 180
    $0 --remove-key --host homeserver                        # remove your default key
    $0 --remove-key --alias homeserver --pubkey ~/.ssh/id_ed25519_old.pub
    $0 --bootstrap newbox --host server1 --alias server1
    $0 --bootstrap newbox --hosts-file servers.txt --domain tail1234.ts.net
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
    local now alias file key epoch age status color stamp entries hostw
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

    # Size the HOST column to the widest alias (printf never truncates, so a
    # fixed width would let long hostnames overflow and shove later columns out
    # of alignment). Floor at the "HOST" header width so short lists stay tidy.
    hostw=$(awk -F'\t' 'BEGIN { m = 4 } length($1) > m { m = length($1) } END { print m }' <<< "$entries")

    now=$(date +%s)
    print_info "Checking key ages (rotation due after $MAX_AGE_DAYS days):"
    echo
    printf '  %-*s %-12s %6s  %-14s %s\n' "$hostw" "HOST" "CREATED" "AGE" "STATUS" "KEY"

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
            printf "  %-*s %-12s %6s  ${color}%-14s${NC} %s\n" \
                "$hostw" "$alias" "$stamp" "${age}d" "$status" "$key"
        else
            printf "  %-*s %-12s %6s  ${YELLOW}%-14s${NC} %s\n" \
                "$hostw" "$alias" "-" "-" "key missing" "$key"
        fi
    done <<< "$entries"

    echo
    if (( ${#due[@]} == 0 )); then
        print_success "No keys are due for rotation."
        return 0
    fi

    print_warning "${#due[@]} key(s) due for rotation."
    for alias in "${due[@]}"; do
        # A bare `read` failing (e.g. EOF on a piped/exhausted stdin) would trip
        # set -e and kill the batch mid-way; treat any read failure as "stop".
        if ! read -p "Rotate '$alias' now? (y/N): " -n 1 -r; then
            echo
            print_info "No more input; stopping."
            break
        fi
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Feed do_rotate its stdin from /dev/null so nothing inside it
            # (notably ssh-copy-id, which reads the terminal) can swallow the
            # remaining "Rotate?" answers and strand the rest of the batch.
            do_rotate "$alias" </dev/null || print_error "Rotation of '$alias' failed; continuing with the rest."
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

# Copy config from file $1 to $2, inserting $CONFIG_ENTRY before the first
# universal "Host *" catch-all block (backing up over the comment/blank lines
# that head it). SSH config is first-match-wins, so a specific Host placed after
# a catch-all can be shadowed by any User/IdentityFile/ProxyJump it sets — keep
# specifics above "Host *". Falls back to appending when there is no catch-all.
insert_config_entry() {
    CONFIG_ENTRY="$CONFIG_ENTRY" awk '
        function is_catchall(   i) { for (i = 2; i <= NF; i++) if ($i == "*") return 1; return 0 }
        { lines[NR] = $0 }
        !done && /^[[:space:]]*[Hh]ost[[:space:]]/ && is_catchall() {
            insat = (runstart > 0 ? runstart : NR); done = 1
        }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { if (runstart == 0) runstart = NR; next }
        { runstart = 0 }
        END {
            for (k = 1; k <= NR; k++) {
                if (done && k == insat) print ENVIRON["CONFIG_ENTRY"]
                print lines[k]
            }
            if (!done) print ENVIRON["CONFIG_ENTRY"]
        }
    ' "$1" > "$2"
}

# Recommended "Host *" defaults. Connection multiplexing (ControlMaster/Path/
# Persist) reuses a single connection so scripts that fire many SSH sessions in
# quick succession don't get rate-limited or locked out by the server's
# MaxStartups; the ServerAlive/ConnectTimeout settings keep long or idle
# sessions healthy. Order is the order they'll be written.
RECOMMENDED_CATCHALL=(
    "ConnectTimeout 15"
    "ServerAliveInterval 10"
    "ServerAliveCountMax 2"
    "StrictHostKeyChecking no"
    "ControlMaster auto"
    "ControlPath /tmp/ssh-%r@%h:%p"
    "ControlPersist 300"
)

# Return success if the first universal "Host *" block in $SSH_CONFIG already
# sets keyword $1 (case-insensitive), so we only offer to add what's missing.
catchall_has_keyword() {
    awk -v key="$1" "$AWK_HOST_FUNCS"'
        /^[[:space:]]*[Hh]ost[[:space:]]/ { inblk = host_line_matches("*"); next }
        inblk && tolower($1) == tolower(key) { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$SSH_CONFIG"
}

# During setup, make sure the user has a sensible "Host *" catch-all. If none
# exists, offer to add the full recommended block; if one exists but is missing
# some recommended settings, offer to add just those. Purely advisory — every
# change is behind a prompt, and a complete block is left untouched (and silent).
ensure_catchall_block() {
    local line kw tmp
    local missing=()

    if [[ ! -f "$SSH_CONFIG" ]] || ! host_exists '*' "$SSH_CONFIG"; then
        print_info "No 'Host *' defaults block found in your SSH config."
        echo "  A catch-all with connection multiplexing + keepalives keeps rapid,"
        echo "  repeated SSH connections from being rate-limited or locked out."
        echo "  Proposed block:"
        echo
        echo "    Host *"
        printf '        %s\n' "${RECOMMENDED_CATCHALL[@]}"
        echo
        read -p "Add this 'Host *' block to your SSH config? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            [[ -f "$SSH_CONFIG" ]] && backup_config
            {
                [[ -s "$SSH_CONFIG" ]] && printf '\n'
                printf 'Host *\n'
                printf '    %s\n' "${RECOMMENDED_CATCHALL[@]}"
            } >> "$SSH_CONFIG"
            chmod 600 "$SSH_CONFIG"
            print_success "Added 'Host *' defaults block."
        else
            print_info "Left SSH config defaults unchanged."
        fi
        return 0
    fi

    # Block exists — collect any recommended settings it doesn't already have.
    for line in "${RECOMMENDED_CATCHALL[@]}"; do
        kw=${line%% *}
        catchall_has_keyword "$kw" || missing+=("$line")
    done
    (( ${#missing[@]} == 0 )) && return 0   # already complete; stay quiet

    print_warning "Your 'Host *' block is missing recommended setting(s):"
    printf '        %s\n' "${missing[@]}"
    read -p "Add the missing setting(s) to your 'Host *' block? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        backup_config
        tmp=$(mktemp)
        # Insert the missing directives right after the first "Host *" line.
        MISSING_LINES="$(printf '    %s\n' "${missing[@]}")" \
        awk "$AWK_HOST_FUNCS"'
            !added && /^[[:space:]]*[Hh]ost[[:space:]]/ && host_line_matches("*") {
                # $(...) strips the trailing newline, so re-add it here to keep
                # the last injected directive on its own line.
                print; printf "%s\n", ENVIRON["MISSING_LINES"]; added = 1; next
            }
            { print }
        ' "$SSH_CONFIG" > "$tmp"
        mv "$tmp" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        print_success "Updated 'Host *' block with the missing setting(s)."
    else
        print_info "Left 'Host *' block unchanged."
    fi
}

# Return success if hostname $1 is GitHub (github.com, or a *.github.com host
# such as ssh.github.com). GitHub gives no shell, so its keys can't be rotated
# over the authorized_keys path — do_rotate routes these through the gh CLI.
is_github_host() {
    local h="${1,,}"
    [[ "$h" == "github.com" || "$h" == *.github.com ]]
}

# Preflight the GitHub CLI before a GitHub rotation: gh must be installed,
# authenticated, and hold the admin:public_key scope (needed to add/remove keys).
# Probing the API is the reliable scope test — `gh ssh-key list` only prints a
# warning but can still exit 0 without the scope, whereas `gh api` fails hard.
gh_preflight() {
    if ! command -v gh >/dev/null 2>&1; then
        print_error "This entry is a GitHub host; rotating its key needs the GitHub CLI (gh)."
        print_warning "Install it (e.g. 'pacman -S github-cli') and run 'gh auth login', then retry."
        return 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        print_error "The GitHub CLI is not authenticated. Run 'gh auth login' and retry."
        return 1
    fi
    if ! gh api user/keys >/dev/null 2>&1; then
        print_error "The GitHub CLI lacks the 'admin:public_key' scope needed to manage SSH keys."
        print_warning "Grant it with: gh auth refresh -h github.com -s admin:public_key"
        return 1
    fi
    return 0
}

# Rotate the key for an existing config entry, replacing it in place. Returns
# non-zero (without touching the old key) if anything before the swap fails, so
# a failed rotation can never lock you out.
do_rotate() {
    local target hostname user port old_key old_pub old_blob old_type old_comment
    local key_type bits new_key new_comment installed old_deleted remote_rm
    local provider="ssh" verified vout old_id

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

    # GitHub gives no shell, so the authorized_keys rotation path can't work.
    # Detect it and drive rotation through the GitHub API via the gh CLI instead.
    # The SSH username to GitHub is always "git", regardless of the config's User.
    if is_github_host "$hostname"; then
        provider="github"
        user="git"
        gh_preflight || return 1
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
        old_type=$(awk '{print $1}' "$old_pub")
        old_blob=$(awk '{print $2}' "$old_pub")
        old_comment=$(cut -d' ' -f3- "$old_pub")
    else
        old_type=""
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

    installed=false
    if [[ "$provider" == github ]]; then
        # Register the new public key on the account; gh uses its own token, so
        # this works even when the old private key is already gone.
        print_info "Adding the new public key to your GitHub account..."
        if gh ssh-key add "$new_key.pub" --title "$new_comment"; then
            installed=true
        fi
    else
        # Install the new public key, preferring the old key for non-interactive auth
        print_info "Installing new public key on $user@$hostname:$port..."
        if [[ -f "$old_key" ]] && ssh "${SSH_NOMUX[@]}" -i "$old_key" -p "$port" \
                -o IdentitiesOnly=yes -o BatchMode=yes "$user@$hostname" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
                < "$new_key.pub"; then
            installed=true
        elif command -v ssh-copy-id >/dev/null 2>&1 && \
                ssh-copy-id "${SSH_NOMUX[@]}" -i "$new_key.pub" -p "$port" "$user@$hostname"; then
            installed=true
        elif ssh "${SSH_NOMUX[@]}" -p "$port" "$user@$hostname" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
                < "$new_key.pub"; then
            installed=true
        fi
    fi
    if [[ "$installed" != true ]]; then
        print_error "Could not install the new key. Aborting; nothing changed."
        rm -f "$new_key" "$new_key.pub"
        return 1
    fi
    print_success "New public key installed."

    # Verify the new key BEFORE removing the old one, so a failure can't lock us out
    print_info "Verifying the new key works..."
    # -n: don't let ssh consume our stdin — a --check-age batch reads its
    # "Rotate?" answers from the same terminal after this call returns.
    verified=false
    if [[ "$provider" == github ]]; then
        # GitHub closes the session with exit status 1 even on success, so key
        # off its "successfully authenticated" banner instead of the exit code.
        # Capture first, then grep: piping straight into grep would let pipefail
        # surface ssh's exit 1 and read as a failure.
        vout=$(ssh "${SSH_NOMUX[@]}" -n -i "$new_key" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
                -o ConnectTimeout=10 -T "$user@$hostname" 2>&1) || true
        if grep -qi "successfully authenticated" <<< "$vout"; then
            verified=true
        fi
    elif ssh "${SSH_NOMUX[@]}" -n -i "$new_key" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
            -o ConnectTimeout=10 "$user@$hostname" "true" >/dev/null 2>&1; then
        verified=true
    fi
    if [[ "$verified" != true ]]; then
        print_error "The new key did not authenticate. Aborting rotation; the old key is untouched."
        print_warning "An unused public key may have been added to the ${provider/ssh/server}; remove it manually if desired."
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

    # Remove the old public key. For GitHub, look up its numeric id by matching
    # the stored "<type> <blob>" (GitHub keeps no comment) and delete it via the
    # API. For a regular server, filter it out of authorized_keys using the new
    # key to authenticate; only overwrite when the filtered result is non-empty.
    if [[ "$provider" == github ]]; then
        if [[ -n "$old_blob" ]]; then
            print_info "Removing the old key from your GitHub account..."
            old_id=$(gh api --paginate user/keys --jq '.[] | [.id, .key] | @tsv' 2>/dev/null \
                | awk -F'\t' -v k="$old_type $old_blob" '$2 == k { print $1; exit }') || true
            if [[ -n "$old_id" ]] && gh ssh-key delete "$old_id" --yes >/dev/null 2>&1; then
                print_success "Old key removed from GitHub (id $old_id)."
            else
                print_warning "Could not remove the old key from GitHub automatically."
                print_warning "Delete it manually at https://github.com/settings/keys"
            fi
        fi
    elif [[ -n "$old_blob" ]]; then
        print_info "Removing the old key from the server's authorized_keys..."
        remote_rm="f=\$HOME/.ssh/authorized_keys; if [ -f \"\$f\" ]; then grep -vF '$old_blob' \"\$f\" > \"\$f.tmp\" 2>/dev/null || true; if [ -s \"\$f.tmp\" ]; then mv \"\$f.tmp\" \"\$f\"; chmod 600 \"\$f\"; else rm -f \"\$f.tmp\"; fi; fi"
        if ssh "${SSH_NOMUX[@]}" -n -i "$old_key" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
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
    if [[ -n "$old_blob" ]]; then
        if [[ "$provider" == github ]]; then
            echo "  ✓ Old key removed from GitHub (or manual instructions printed above)"
        else
            echo "  ✓ Old key removed from server (or manual instructions printed above)"
        fi
    fi
    echo
    print_info "Connect as usual:"
    echo "  ssh $target"
    return 0
}

# Remove a public key from a server's authorized_keys — the inverse of the
# install step. Target the host by --host (or --alias, which reads
# HostName/User/Port from ~/.ssh/config); pick the key to remove with --pubkey
# <file> or --key '<literal>' (default: ~/.ssh/id_ed25519.pub). Matching is on
# the key's base64 blob, so the comment is irrelevant, and the server refuses to
# empty authorized_keys (so you can't strand yourself without any key).
do_remove_key() {
    local target hostname user port auth_key pub blob desc result
    local ssh_auth=()

    target="${ALIAS:-$HOST}"
    if [[ -z "$target" ]]; then
        print_error "Remove-key needs a target. Use --host <host> or --alias <name>."
        return 1
    fi

    # Prefer a matching config entry (for HostName/User/Port and an identity to
    # authenticate with); otherwise fall back to the --host/--user/--port flags.
    if [[ -f "$SSH_CONFIG" ]] && host_exists "$target" "$SSH_CONFIG"; then
        hostname=$(config_get "$target" HostName); hostname="${hostname:-$target}"
        user=$(config_get "$target" User);         user="${user:-$REMOTE_USER}"
        port=$(config_get "$target" Port);         port="${port:-$PORT}"
        auth_key=$(config_get "$target" IdentityFile); auth_key="${auth_key/#\~/$HOME}"
    else
        hostname="$target"; user="$REMOTE_USER"; port="$PORT"; auth_key=""
    fi

    # Resolve the key blob to remove: a literal string wins, else a .pub file.
    if [[ -n "$REMOVE_KEY_LITERAL" ]]; then
        blob=$(awk '{print ($2 != "" ? $2 : $1)}' <<< "$REMOVE_KEY_LITERAL")
        desc="(literal key)"
    else
        pub="${REMOVE_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
        pub="${pub/#\~/$HOME}"
        if [[ ! -f "$pub" ]]; then
            print_error "Public key file not found: $pub"
            print_info "Pass --pubkey <file> or --key '<ssh-... AAAA...>'."
            return 1
        fi
        blob=$(awk '{print $2}' "$pub")
        desc="$pub"
    fi
    if [[ -z "$blob" ]]; then
        print_error "Could not read a key blob to remove from ${desc}."
        return 1
    fi

    # Authenticate with the entry's own key when we have one, so we're not
    # relying on (and possibly about to remove) the key being deleted.
    if [[ -n "$auth_key" && -f "$auth_key" ]]; then
        ssh_auth=(-i "$auth_key" -o IdentitiesOnly=yes)
    fi

    print_info "Removing key from $user@$hostname:$port"
    echo "  Key: $desc"

    # -n keeps ssh off our stdin (safe if ever called in a loop); no BatchMode,
    # so a passphrase/password prompt can still appear for the auth key.
    # REMOVED / ABSENT / ONLYKEY / NOFILE are reported back for an honest result.
    local remote_rm="f=\$HOME/.ssh/authorized_keys
if [ ! -f \"\$f\" ]; then echo NOFILE; exit 0; fi
if ! grep -qF '$blob' \"\$f\"; then echo ABSENT; exit 0; fi
grep -vF '$blob' \"\$f\" > \"\$f.tmp\" 2>/dev/null || true
if [ -s \"\$f.tmp\" ]; then mv \"\$f.tmp\" \"\$f\"; chmod 600 \"\$f\"; echo REMOVED; else rm -f \"\$f.tmp\"; echo ONLYKEY; fi"

    if ! result=$(ssh "${SSH_NOMUX[@]}" -n "${ssh_auth[@]}" -p "$port" \
            -o ConnectTimeout=10 "$user@$hostname" "$remote_rm"); then
        print_error "Could not connect to $user@$hostname:$port to remove the key."
        return 1
    fi

    case "$result" in
        REMOVED) print_success "Key removed from $user@$hostname." ;;
        ABSENT)  print_info "That key isn't in authorized_keys on $user@$hostname — nothing to do." ;;
        NOFILE)  print_info "No authorized_keys file on $user@$hostname — nothing to do." ;;
        ONLYKEY) print_warning "That key is the ONLY authorized key on $user@$hostname — refused (removing it would lock you out)."
                 print_warning "Add another key first, or remove it by hand if you're sure."
                 return 1 ;;
        *)       print_warning "Unexpected response from $user@$hostname: ${result:-<empty>}"; return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Bootstrap mode: set up ANOTHER machine's key access to servers that THIS
# machine can already reach. Solves the chicken-and-egg problem of a brand new
# machine and a fleet with "PasswordAuthentication no": there is no way in to
# run ssh-copy-id from, so the key has to be placed using an existing machine's
# working access. The private key is generated on the new machine and never
# leaves it — only the .pub travels.
# ---------------------------------------------------------------------------

# Names that get interpolated into the remote shell snippets below are limited
# to characters with no meaning to a shell, so nothing needs quoting on the far
# side and a stray hosts-file line can't smuggle in a command.
valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# Split a target spec "[user@]host[:port]" into SPEC_USER/SPEC_NAME/SPEC_PORT,
# appending --domain to a bare (dotless) name. Used both per host and up front,
# so the alias a batch will derive is known before anything is touched.
SPEC_USER=""
SPEC_NAME=""
SPEC_PORT=""
parse_target_spec() {
    local s="$1"
    SPEC_USER=""
    SPEC_PORT=""
    if [[ "$s" == *@* ]]; then SPEC_USER="${s%%@*}"; s="${s#*@}"; fi
    if [[ "$s" == *:* ]]; then SPEC_PORT="${s##*:}"; s="${s%:*}"; fi
    if [[ -n "$DOMAIN" && "$s" != *.* ]]; then s="$s.$DOMAIN"; fi
    SPEC_NAME="$s"
}

# Ask ssh itself what it would use for a name, into CFG_USER/CFG_HOSTNAME/
# CFG_PORT. "ssh -G" applies the whole config the way a real connection would —
# including wildcard patterns ("Host *.example.com") and Match blocks, which an
# exact-alias lookup misses, and which is exactly how fleets tend to be
# configured. For a name with no config at all it just echoes back the defaults.
CFG_USER=""
CFG_HOSTNAME=""
CFG_PORT=""
resolve_ssh_config() {
    local g
    CFG_USER=""; CFG_HOSTNAME=""; CFG_PORT=""
    g=$(ssh -G "$1" 2>/dev/null) || return 1
    CFG_USER=$(awk 'tolower($1) == "user" { print $2; exit }' <<< "$g")
    CFG_HOSTNAME=$(awk 'tolower($1) == "hostname" { print $2; exit }' <<< "$g")
    CFG_PORT=$(awk 'tolower($1) == "port" { print $2; exit }' <<< "$g")
    [[ -n "$CFG_HOSTNAME" ]]
}

# Generate the key on the new machine if it isn't already there (re-running the
# batch reuses it), then print "GENERATED"/"REUSED" and the public key.
# Expects: keyfile, keytype, keybits, target_host, today.
read -r -d '' REMOTE_GEN_SH <<'REMOTE_GEN_EOF' || true
set -e
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
k="$HOME/.ssh/$keyfile"
if [ -f "$k" ]; then
    status=REUSED
else
    c="$(id -un)@$(hostname 2>/dev/null || uname -n)_to_${target_host} (created ${today})"
    if [ "$keytype" = ed25519 ]; then
        ssh-keygen -t ed25519 -N '' -C "$c" -f "$k" >/dev/null
    else
        ssh-keygen -t "$keytype" -b "$keybits" -N '' -C "$c" -f "$k" >/dev/null
    fi
    status=GENERATED
fi
[ -f "$k.pub" ] || ssh-keygen -y -f "$k" > "$k.pub"
chmod 600 "$k"
chmod 644 "$k.pub"
printf '%s\n' "$status"
cat "$k.pub"
REMOTE_GEN_EOF

# Append the public key (read from stdin) to the target server's
# authorized_keys, unless the same key material is already there. Matching is on
# the base64 blob, not the whole line, so a re-run with a different comment
# doesn't add a duplicate.
read -r -d '' REMOTE_ADD_KEY_SH <<'REMOTE_ADD_EOF' || true
set -e
umask 077
newkey=$(cat)
blob=$(printf '%s\n' "$newkey" | awk '{print $2}')
if [ -z "$blob" ]; then printf 'BADKEY\n'; exit 0; fi
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
f="$HOME/.ssh/authorized_keys"
[ -f "$f" ] || : > "$f"
if awk -v b="$blob" '{ for (i = 1; i <= NF; i++) if ($i == b) found = 1 } END { exit found ? 0 : 1 }' "$f"; then
    chmod 600 "$f"
    printf 'PRESENT\n'
else
    printf '%s\n' "$newkey" >> "$f"
    chmod 600 "$f"
    printf 'ADDED\n'
fi
REMOTE_ADD_EOF

# Write the Host entry (read from stdin) into the new machine's ~/.ssh/config:
# drop any existing block for the same alias, then insert above the first
# "Host *" catch-all — the same first-match-wins ordering the local path uses.
# Expects: alias_name, do_backup.
read -r -d '' REMOTE_CONFIG_SH <<'REMOTE_CONFIG_EOF' || true
set -e
umask 077
entry=$(cat)
cfg="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
# ~/.ssh/config is often a symlink into a dotfiles repo. Resolve it and write
# THROUGH the link (cat >), so the link isn't replaced by a regular file and the
# dotfiles copy left orphaned.
real="$cfg"
if [ -L "$cfg" ]; then
    real=$(readlink -f "$cfg" 2>/dev/null) || real="$cfg"
    [ -n "$real" ] || real="$cfg"
fi
[ -f "$real" ] || : > "$real"
if [ "$do_backup" = 1 ] && [ -s "$real" ]; then
    cp "$real" "$real.backup.$(date +%Y%m%d_%H%M%S)"
fi
t1=$(mktemp)
t2=$(mktemp)
awk -v host="$alias_name" '
    function host_line_matches(host,   i) {
        for (i = 2; i <= NF; i++) if ($i == host) return 1
        return 0
    }
    function flush() { printf "%s", buf; buf = "" }
    # A Host/Match line is the only thing that ends a block: an ssh_config block
    # runs to the next one, blank lines and comments included.
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
        skip = 0
        if (host_line_matches(host)) { skip = 1; buf = ""; next }
        flush(); print; next
    }
    /^[[:space:]]*[Mm]atch[[:space:]]/ { skip = 0; flush(); print; next }
    # Comments and blank lines are buffered rather than emitted: a run of them
    # directly above a block heads THAT block, so it has to survive even when it
    # sits inside the one being removed. A directive line proves the run was
    # interior to the removed block, so it is dropped there.
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { buf = buf $0 "\n"; next }
    { if (skip) { buf = ""; next } flush(); print }
    END { if (!skip) flush() }
' "$real" > "$t1"
ENTRY="$entry" awk '
    function is_catchall(   i) { for (i = 2; i <= NF; i++) if ($i == "*") return 1; return 0 }
    { lines[NR] = $0 }
    !done && /^[[:space:]]*[Hh]ost[[:space:]]/ && is_catchall() {
        insat = (runstart > 0 ? runstart : NR); done = 1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { if (runstart == 0) runstart = NR; next }
    { runstart = 0 }
    END {
        for (k = 1; k <= NR; k++) {
            if (done && k == insat) print ENVIRON["ENTRY"]
            print lines[k]
        }
        if (!done) print ENVIRON["ENTRY"]
    }
' "$t1" > "$t2"
cat "$t2" > "$real"
chmod 600 "$real"
rm -f "$t1" "$t2"
printf 'WROTE\n'
REMOTE_CONFIG_EOF

# Connections to the machine being bootstrapped go over a control socket THIS
# run creates in a private temp dir: one authentication for the whole batch (the
# machine may only be reachable by password yet), with no risk of riding a
# pre-existing master socket that points somewhere else.
BOOTSTRAP_CTL_DIR=""
bootstrap_cleanup() {
    [[ -n "$BOOTSTRAP_CTL_DIR" ]] || return 0
    ssh -o ControlPath="$BOOTSTRAP_CTL_DIR/ctl" -O exit "$BOOTSTRAP" >/dev/null 2>&1 || true
    rm -rf "$BOOTSTRAP_CTL_DIR"
    BOOTSTRAP_CTL_DIR=""
}

machine_ssh() {
    ssh -o ControlMaster=auto -o ControlPath="$BOOTSTRAP_CTL_DIR/ctl" -o ControlPersist=60 \
        -o ConnectTimeout=15 "$BOOTSTRAP" "$@"
}

# Bootstrap one server. Every failure is local to this host: it returns non-zero
# and the batch carries on with the next one.
BOOTSTRAP_CONFIG_BACKED_UP=false
BOOTSTRAP_FAIL_REASON=""
bootstrap_one() {
    local spec="$1"
    local name user port hostname alias key_prefix key_base pub comment
    local out status entry do_backup

    BOOTSTRAP_FAIL_REASON=""

    parse_target_spec "$spec"
    name="$SPEC_NAME"
    user="$SPEC_USER"
    port="$SPEC_PORT"

    if ! valid_name "$name"; then
        BOOTSTRAP_FAIL_REASON="invalid host name '$name'"
        return 1
    fi
    if [[ -n "$user" ]] && ! valid_name "$user"; then
        BOOTSTRAP_FAIL_REASON="invalid user name '$user'"
        return 1
    fi
    if [[ -n "$port" ]] && ! [[ "$port" =~ ^[0-9]+$ ]]; then
        BOOTSTRAP_FAIL_REASON="invalid port '$port'"
        return 1
    fi

    # Take the settings this machine already uses for the server — they are what
    # the new machine needs in its own config, and they let ssh authenticate here
    # with the identity that already works. Explicit values win over the config:
    # a spec's user@/:port first, then --user/--port, then what ssh resolves.
    if resolve_ssh_config "$name"; then
        hostname="$CFG_HOSTNAME"
        if [[ -z "$user" ]]; then
            [[ "$REMOTE_USER_SET" == true ]] && user="$REMOTE_USER" || user="$CFG_USER"
        fi
        if [[ -z "$port" ]]; then
            [[ "$PORT_SET" == true ]] && port="$PORT" || port="$CFG_PORT"
        fi
    else
        hostname="$name"
    fi
    user="${user:-$REMOTE_USER}"
    port="${port:-$PORT}"
    if ! valid_name "$hostname"; then
        BOOTSTRAP_FAIL_REASON="invalid HostName '$hostname'"
        return 1
    fi

    # Connect by NAME so any config for it (identity, ProxyJump, wildcard block)
    # still applies, but pin the user and port to what we resolved — otherwise a
    # spec like "otheruser@server:2222" would install the key into the account
    # the config names while the entry we write points somewhere else.
    local ssh_target=(-l "$user" -p "$port" "$name")

    # One alias per server on the new machine: --alias when a single --host was
    # given, otherwise the short name (first label) of the server.
    alias="$ALIAS"
    [[ -n "$alias" ]] || alias="${name%%.*}"
    if ! valid_name "$alias"; then
        BOOTSTRAP_FAIL_REASON="invalid alias '$alias'"
        return 1
    fi

    case "$KEY_TYPE" in
        ed25519) key_prefix="id_ed25519" ;;
        rsa)     key_prefix="id_rsa" ;;
        ecdsa)   key_prefix="id_ecdsa" ;;
    esac
    key_base="${key_prefix}_${KEY_NAME:-$alias}"
    if ! valid_name "$key_base"; then
        BOOTSTRAP_FAIL_REASON="invalid key name '${KEY_NAME:-$alias}'"
        return 1
    fi

    print_info "Bootstrapping $BOOTSTRAP -> $user@$hostname:$port (alias '$alias')"

    # Confirm the server we're about to add a key to is the host we think it is,
    # before anything is generated or written.
    if ! verify_host_identity "$hostname" "$port"; then
        BOOTSTRAP_FAIL_REASON="host identity not confirmed"
        return 1
    fi

    # 1. Generate the key ON the new machine. The private key never moves.
    if ! out=$(machine_ssh "keyfile=$key_base keytype=$KEY_TYPE keybits=$KEY_BITS target_host=$name today=$(date +%Y-%m-%d)
$REMOTE_GEN_SH" </dev/null); then
        BOOTSTRAP_FAIL_REASON="could not generate the key on $BOOTSTRAP"
        return 1
    fi
    status=$(head -n1 <<< "$out")
    pub=$(sed -n '2p' <<< "$out")
    if [[ -z "$pub" || "$pub" != ssh-* && "$pub" != ecdsa-* && "$pub" != sk-* ]]; then
        BOOTSTRAP_FAIL_REASON="no public key returned from $BOOTSTRAP"
        return 1
    fi
    case "$status" in
        GENERATED) print_success "  Key generated on $BOOTSTRAP: ~/.ssh/$key_base" ;;
        *)         print_info "  Reusing existing key on $BOOTSTRAP: ~/.ssh/$key_base" ;;
    esac

    # 2. Install the public key on the server, using THIS machine's access.
    if ! out=$(ssh "${SSH_NOMUX[@]}" -o ConnectTimeout=15 "${ssh_target[@]}" \
            "$REMOTE_ADD_KEY_SH" <<< "$pub"); then
        BOOTSTRAP_FAIL_REASON="could not reach $user@$hostname:$port from here"
        return 1
    fi
    case "$out" in
        ADDED)   print_success "  Public key added to $user@$hostname:$port" ;;
        PRESENT) print_info "  Public key already in authorized_keys on $user@$hostname:$port" ;;
        *)       BOOTSTRAP_FAIL_REASON="unexpected response installing the key: ${out:-<empty>}"
                 return 1 ;;
    esac

    # 3. Write the Host entry on the new machine (~ is expanded by ssh there, so
    #    we don't need to know its home directory).
    comment=$(cut -d' ' -f3- <<< "$pub")
    entry="
# ${comment:-$alias}
Host $alias
    HostName $hostname
    User $user
    Port $port
    IdentityFile ~/.ssh/$key_base
    IdentitiesOnly yes
"
    do_backup=0
    [[ "$BOOTSTRAP_CONFIG_BACKED_UP" == false ]] && do_backup=1
    if ! out=$(machine_ssh "alias_name=$alias do_backup=$do_backup
$REMOTE_CONFIG_SH" <<< "$entry") || [[ "$out" != WROTE ]]; then
        BOOTSTRAP_FAIL_REASON="key installed, but the SSH config entry on $BOOTSTRAP failed"
        return 1
    fi
    BOOTSTRAP_CONFIG_BACKED_UP=true
    print_success "  SSH config entry '$alias' written on $BOOTSTRAP"

    # 4. Verify by having the NEW machine actually connect to the server with
    #    the new key. ControlPath=none + IdentitiesOnly=yes are essential: an
    #    open multiplexed session (or another key that happens to work) would
    #    make a broken key look fine and give a false green.
    if ! machine_ssh "ssh -o ControlPath=none -o IdentitiesOnly=yes -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
            -i ~/.ssh/$key_base -p $port $user@$hostname true" </dev/null >/dev/null 2>&1; then
        BOOTSTRAP_FAIL_REASON="$BOOTSTRAP could not authenticate to $user@$hostname:$port with the new key"
        return 1
    fi
    print_success "  Verified: $BOOTSTRAP can now 'ssh $alias'"
    return 0
}

# Drive the bootstrap over one or many servers, failing per host rather than
# per run, and print a summary at the end.
do_bootstrap() {
    local targets=() line spec ok=() failed=()
    local name reason

    case "$KEY_TYPE" in
        ed25519|rsa) ;;
        # --bits defaults to an RSA size; ECDSA only accepts 256/384/521, so an
        # untouched default would fail on the far side. Match the setup path's 521.
        ecdsa) [[ "$KEY_BITS" == 4096 ]] && KEY_BITS=521 ;;
        *) print_error "Invalid key type: $KEY_TYPE. Supported types: ed25519, rsa, ecdsa"
           return 1 ;;
    esac

    if [[ -n "$HOSTS_FILE" ]]; then
        if [[ ! -f "$HOSTS_FILE" ]]; then
            print_error "Hosts file not found: $HOSTS_FILE"
            return 1
        fi
        # Read the whole list up front so stdin stays the terminal — the host
        # identity check below may need to ask a question.
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -n "$line" ]] && targets+=("$line")
        done < "$HOSTS_FILE"
    fi
    [[ -n "$HOST" ]] && targets+=("$HOST")

    if (( ${#targets[@]} == 0 )); then
        print_error "Bootstrap needs at least one server. Use --host <server> or --hosts-file <file>."
        return 1
    fi
    if [[ -n "$ALIAS" && ${#targets[@]} -gt 1 ]]; then
        print_error "--alias applies to a single server; with multiple servers the alias is derived from each name."
        return 1
    fi
    if [[ -n "$KEY_NAME" && ${#targets[@]} -gt 1 ]]; then
        print_error "--name applies to a single server; with multiple servers the key name is derived from each alias."
        return 1
    fi

    # Derived aliases have to be unique. "web.prod.example.com" and
    # "web.staging.example.com" both shorten to "web", which would share one key
    # and overwrite each other's config entry while the summary claimed both
    # succeeded — catch it before anything is written.
    if [[ -z "$ALIAS" && ${#targets[@]} -gt 1 ]]; then
        local dupes
        dupes=$(for spec in "${targets[@]}"; do
                    parse_target_spec "$spec"; printf '%s\n' "${SPEC_NAME%%.*}"
                done | sort | uniq -d)
        if [[ -n "$dupes" ]]; then
            print_error "These servers shorten to the same alias, so they'd overwrite each other:"
            while IFS= read -r line; do echo "    $line"; done <<< "$dupes"
            print_info "Bootstrap them one at a time with --host <server> --alias <unique-name>."
            return 1
        fi
    fi

    print_info "Bootstrapping SSH access for '$BOOTSTRAP' to ${#targets[@]} server(s)."
    echo "  Keys are generated on '$BOOTSTRAP' — no private key is ever copied."
    echo

    # Confirm the machine we're about to run commands on is the one we mean,
    # BEFORE any remote code runs. If the name resolved to the wrong box (or a
    # spoofed one), it would otherwise hand us a public key that we'd then go
    # and install on every server in the batch.
    local m_host m_port
    if resolve_ssh_config "$BOOTSTRAP"; then
        m_host="$CFG_HOSTNAME"; m_port="${CFG_PORT:-22}"
    else
        m_host="$BOOTSTRAP"; m_port=22
    fi
    if ! verify_host_identity "$m_host" "$m_port"; then
        print_error "Aborting: the identity of '$BOOTSTRAP' could not be confirmed."
        return 1
    fi

    BOOTSTRAP_CTL_DIR=$(mktemp -d)
    trap bootstrap_cleanup EXIT
    trap 'bootstrap_cleanup; exit 130' INT
    trap 'bootstrap_cleanup; exit 143' TERM

    # One connection up front: it opens the shared control socket (so a password
    # prompt happens at most once) and proves the machine has everything the
    # later steps need — including the ssh CLIENT, which the final verification
    # runs. Checking it here means a machine with sshd but no client can't get
    # halfway through and leave a key installed on servers it can't use.
    if ! machine_ssh 'command -v ssh >/dev/null && command -v ssh-keygen >/dev/null && command -v awk >/dev/null' </dev/null; then
        print_error "Cannot reach '$BOOTSTRAP', or it lacks ssh/ssh-keygen/awk."
        print_info "The machine being bootstrapped must be reachable from here (password auth is fine)."
        return 1
    fi

    for spec in "${targets[@]}"; do
        if bootstrap_one "$spec"; then
            ok+=("$spec")
        else
            print_error "  Failed: ${BOOTSTRAP_FAIL_REASON:-unknown error}"
            failed+=("$spec	${BOOTSTRAP_FAIL_REASON:-unknown error}")
        fi
        echo
    done

    print_info "Bootstrap summary for '$BOOTSTRAP':"
    for spec in ${ok[@]+"${ok[@]}"}; do
        echo -e "  ${GREEN}ok${NC}      $spec"
    done
    for spec in ${failed[@]+"${failed[@]}"}; do
        IFS=$'\t' read -r name reason <<< "$spec"
        echo -e "  ${RED}failed${NC}  $name — $reason"
    done
    echo
    if (( ${#failed[@]} == 0 )); then
        print_success "${#ok[@]} of ${#targets[@]} server(s) bootstrapped."
    else
        print_warning "${#ok[@]} of ${#targets[@]} server(s) bootstrapped; ${#failed[@]} failed."
    fi

    if (( ${#ok[@]} > 0 )); then
        echo
        print_info "'$BOOTSTRAP' now has its own key on each server above. If you had put a"
        print_info "shared key on them to get this far, it is now redundant — remove it with:"
        echo "  ssh-setup --remove-key --host <server> --pubkey ~/.ssh/<shared-key>.pub"
    fi

    (( ${#failed[@]} == 0 ))
}

# Preflight the target's SSH host identity BEFORE generating or copying a key.
# The script's connections inherit the user's "Host *" settings, which may
# include "StrictHostKeyChecking no" — so a name that has silently resolved to
# the WRONG host (e.g. a DNS wildcard fall-through when its real record is
# momentarily missing) would be trusted and handed our key. This catches that:
# a CHANGED host key aborts, an UNKNOWN host key shows the fingerprint + resolved
# IP and asks, and a host key that matches known_hosts proceeds quietly.
verify_host_identity() {
    local host="$1" port="$2" scan ips known_pairs scan_pairs changed=0 ktype kblob sblob reply

    ips=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd', ' -)

    # A raw protocol handshake (no auth, no ControlMaster) to read the host key.
    scan=$(ssh-keyscan -T 7 -p "$port" "$host" 2>/dev/null)
    if [[ -z "$scan" ]]; then
        print_warning "Couldn't read $host's host key (host down or filtered) — skipping identity check."
        return 0
    fi
    scan_pairs=$(awk '!/^#/ && NF>=3 { print $(NF-1), $NF }' <<< "$scan")

    if ! known_pairs=$(ssh-keygen -F "$host" 2>/dev/null | awk '!/^#/ && NF>=3 { print $(NF-1), $NF }') \
            || [[ -z "$known_pairs" ]]; then
        # UNKNOWN host: normal for a genuine first-time setup, but also exactly what
        # a fall-through to a brand-new wrong host looks like — surface and confirm.
        print_warning "The host key for '$host' is not yet in known_hosts."
        [[ -n "$ips" ]] && echo "  Resolves to: $ips"
        echo "  Presented host key(s):"
        printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /'
        echo "  Make sure this is the host you expect — a bare name can resolve to a"
        echo "  wildcard/ingress box if its real DNS record is momentarily missing."
        read -rp "  Trust this host and continue? (y/N): " -n 1 reply || reply=""
        echo
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            print_error "Aborted: host identity not confirmed for '$host'."
            return 1
        fi
        return 0
    fi

    # Known host: detect a CHANGED key the way ssh does — a key type present in
    # both known_hosts and the server's current offer whose material differs.
    while read -r ktype kblob; do
        [[ -z "$ktype" ]] && continue
        sblob=$(awk -v t="$ktype" '$1 == t { print $2; exit }' <<< "$scan_pairs")
        [[ -n "$sblob" && "$sblob" != "$kblob" ]] && changed=1
    done <<< "$known_pairs"

    if (( changed )); then
        print_error "Host key for '$host' does NOT match ~/.ssh/known_hosts — refusing to continue."
        [[ -n "$ips" ]] && echo "  '$host' currently resolves to: $ips"
        echo "  Now presented:"
        printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /'
        echo "  Previously trusted:"
        ssh-keygen -lF "$host" 2>/dev/null | grep -v '^#' | sed 's/^/    /'
        echo
        print_warning "This usually means one of:"
        echo "    - the name resolved to a DIFFERENT host (e.g. DNS wildcard fall-through)"
        echo "    - the server was legitimately reinstalled (new host key)"
        echo "  Check where it points first:  getent hosts $host"
        echo "  If the change is expected, clear the old key and retry:  ssh-keygen -R '$host'"
        return 1
    fi

    print_info "Host key for '$host' verified against known_hosts."
    return 0
}

# Default values (REMOTE_USER defaults to the local user once resolved below)
REMOTE_USER=""
REMOTE_USER_SET=false
PORT=22
PORT_SET=false
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
REMOVE_KEY=false
REMOVE_PUBKEY=""
REMOVE_KEY_LITERAL=""
BOOTSTRAP=""
HOSTS_FILE=""
DOMAIN=""

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
            PORT_SET=true
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
        --remove-key)
            REMOVE_KEY=true
            shift
            ;;
        --pubkey)
            if [[ $# -lt 2 ]]; then
                print_error "--pubkey requires a path to a .pub file."
                exit 1
            fi
            REMOVE_PUBKEY="$2"
            shift 2
            ;;
        --key)
            if [[ $# -lt 2 ]]; then
                print_error "--key requires a public key string (e.g. 'ssh-ed25519 AAAA...')."
                exit 1
            fi
            REMOVE_KEY_LITERAL="$2"
            shift 2
            ;;
        --bootstrap)
            if [[ $# -lt 2 ]]; then
                print_error "--bootstrap requires the machine to set up (e.g. --bootstrap newbox)."
                exit 1
            fi
            BOOTSTRAP="$2"
            shift 2
            ;;
        --hosts-file)
            if [[ $# -lt 2 ]]; then
                print_error "--hosts-file requires a path to a file listing servers."
                exit 1
            fi
            HOSTS_FILE="$2"
            shift 2
            ;;
        --domain)
            if [[ $# -lt 2 ]]; then
                print_error "--domain requires a domain suffix (e.g. --domain example.com)."
                exit 1
            fi
            DOMAIN="${2#.}"
            shift 2
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

# Bootstrap mode: set up a DIFFERENT machine's access to one or more servers,
# using this machine's existing access, then exit.
if [[ -n "$BOOTSTRAP" ]]; then
    if [[ "$ROTATE" == true || "$CHECK_AGE" == true || "$REMOVE_KEY" == true ]]; then
        print_error "--bootstrap cannot be combined with --rotate, --check-age or --remove-key."
        exit 1
    fi
    do_bootstrap
    exit $?
fi

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

# Remove-key mode: delete a public key from a server's authorized_keys, then exit.
if [[ "$REMOVE_KEY" == true ]]; then
    do_remove_key
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

# Confirm we're about to hand our key to the host we think we are — catching a
# DNS fall-through or a changed host key before anything is generated or copied.
if ! verify_host_identity "$HOST" "$PORT"; then
    exit 1
fi

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
    ssh "${SSH_NOMUX[@]}" -p "$PORT" "$REMOTE_USER@$HOST" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
        < "$KEY_FILE.pub"
}

# Try ssh-copy-id first, fall back to the manual method if it is missing or fails.
# Each command is the condition of an if, so set -e does not abort before we react.
if command -v ssh-copy-id >/dev/null 2>&1; then
    if ssh-copy-id "${SSH_NOMUX[@]}" -i "$KEY_FILE.pub" -p "$PORT" "$REMOTE_USER@$HOST"; then
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

# Offer to set up (or complete) a "Host *" defaults block first, so the specific
# entry we add below lands above it (first-match-wins ordering).
ensure_catchall_block

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
            # then re-insert the new entry above the "Host *" catch-all. Only a
            # Host/Match line ends a block (blank lines inside one don't), and
            # buffered comment/blank lines are dropped when they turn out to be
            # interior to the removed block and flushed (kept) otherwise.
            REMOVED=$(mktemp)
            awk -v host="$ALIAS" "$AWK_HOST_FUNCS"'
                function flush() { printf "%s", buf; buf = "" }
                /^[[:space:]]*[Hh]ost[[:space:]]/ {
                    skip = 0
                    if (host_line_matches(host)) { skip = 1; buf = ""; next }
                    flush(); print; next
                }
                /^[[:space:]]*[Mm]atch[[:space:]]/ { skip = 0; flush(); print; next }
                /^[[:space:]]*#/ || /^[[:space:]]*$/ { buf = buf $0 "\n"; next }
                { if (skip) { buf = ""; next } flush(); print }
                END { if (!skip) flush() }
            ' "$SSH_CONFIG" > "$REMOVED"
            insert_config_entry "$REMOVED" "$TEMP_CONFIG"
            rm -f "$REMOVED"
            mv "$TEMP_CONFIG" "$SSH_CONFIG"
            print_success "SSH config updated (replaced existing entry)"
        else
            print_info "SSH config left unchanged"
        fi
    else
        # Add new entry above the "Host *" catch-all (first-match-wins ordering)
        backup_config
        insert_config_entry "$SSH_CONFIG" "$TEMP_CONFIG"
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
if ssh "${SSH_NOMUX[@]}" -o ConnectTimeout=10 -o BatchMode=yes "$ALIAS" "echo 'SSH connection successful'" 2>/dev/null; then
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
