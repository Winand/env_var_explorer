#!/usr/bin/env bash
# find_env_var.sh — locate where an environment variable is defined
# Works without root; silently skips files/dirs that are not readable.
#
# Usage:   ./find_env_var.sh VARNAME [--pid PID]
# Example: ./find_env_var.sh AIRFLOW_HOME
#          ./find_env_var.sh AIRFLOW_HOME --pid 1234

RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
DIM='\033[2m'
RST='\033[0m'

usage() {
    echo "Usage: $0 VARNAME [--pid PID]"
    echo "  VARNAME   environment variable to search for (e.g. AIRFLOW_HOME)"
    echo "  --pid     also inspect /proc/<pid>/environ for a specific process"
    exit 1
}

[[ $# -lt 1 ]] && usage

VARNAME="$1"
TARGET_PID=""
FOUND=0
SKIPPED=0

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pid) TARGET_PID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

header() { echo -e "\n${BLD}${CYN}=== $1 ===${RST}"; }

skip_msg() { echo -e "  ${DIM}(skipped — not readable: $1)${RST}"; SKIPPED=1; }

# Search a single file; silently skip if unreadable
search_file() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    if [[ ! -r "$file" ]]; then
        skip_msg "$file"
        return 0
    fi
    local matches
    matches=$(grep -nE "(^|[[:space:]]|;)export[[:space:]]+${VARNAME}[=[:space:]]|^[[:space:]]*${VARNAME}[[:space:]]*=" \
              "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        echo -e "  ${GRN}✔ ${file}${RST}"
        while IFS= read -r line; do
            echo -e "    ${YEL}${line}${RST}"
        done <<< "$matches"
        FOUND=1
    fi
}

# Search files under a directory; suppress permission-denied noise from find
search_dir() {
    local dir="$1"
    local depth="${2:-1}"
    [[ -d "$dir" ]] || return 0
    if [[ ! -r "$dir" ]]; then
        skip_msg "$dir"
        return 0
    fi
    while IFS= read -r -d '' f; do
        search_file "$f"
    done < <(find "$dir" -maxdepth "$depth" -type f \
              \( -name "*.sh" -o -name "*.conf" -o -name "*.env" -o -name "profile" \) \
              -print0 2>/dev/null)
}

# ── 1. System-wide shell init ──────────────────────────────────────────────────
header "System-wide shell init"
search_file /etc/environment
search_file /etc/profile
search_dir  /etc/profile.d 1

# ── 2. User shell init ─────────────────────────────────────────────────────────
header "User shell init files"
for home_dir in /root /home/*; do
    [[ -d "$home_dir" ]] || continue
    for rc in .bash_profile .bash_login .profile .bashrc .zshrc .zprofile; do
        search_file "$home_dir/$rc"
    done
done

# ── 3. PAM environment ─────────────────────────────────────────────────────────
header "PAM environment"
search_file /etc/security/pam_env.conf
search_dir  /etc/security 1

# ── 4. systemd units & drop-ins ───────────────────────────────────────────────
header "systemd unit files"
for unit_dir in \
    /etc/systemd/system \
    /usr/lib/systemd/system \
    /run/systemd/system
do
    [[ -d "$unit_dir" ]] || continue
    if [[ ! -r "$unit_dir" ]]; then
        skip_msg "$unit_dir"
        continue
    fi
    while IFS= read -r -d '' f; do
        [[ -r "$f" ]] || continue
        if grep -qiE "^\s*(Environment|EnvironmentFile).*${VARNAME}" "$f" 2>/dev/null; then
            echo -e "  ${GRN}✔ ${f}${RST}"
            grep -niE "^\s*(Environment|EnvironmentFile).*${VARNAME}|^\s*EnvironmentFile" "$f" \
                2>/dev/null | while IFS= read -r line; do
                echo -e "    ${YEL}${line}${RST}"
            done
            FOUND=1
        fi
    done < <(find "$unit_dir" -maxdepth 2 -type f -print0 2>/dev/null)
done

# ── 5. Common application / sysconfig dirs ────────────────────────────────────
header "Application / sysconfig files"
search_dir /etc/sysconfig    1
search_dir /etc/default      1
search_dir /etc/conf.d       1
search_dir /etc/environment.d 1

# ── 6. Docker / compose env files ─────────────────────────────────────────────
header "Docker compose / .env files"
for base_dir in /opt /srv /app /var/lib/docker/volumes; do
    [[ -d "$base_dir" ]] || continue
    if [[ ! -r "$base_dir" ]]; then
        skip_msg "$base_dir"
        continue
    fi
    while IFS= read -r -d '' f; do
        search_file "$f"
    done < <(find "$base_dir" -maxdepth 4 -type f \
              \( -name ".env" -o -name "*.env" -o -name "docker-compose*.yml" \) \
              -print0 2>/dev/null)
done

# ── 7. Live processes ──────────────────────────────────────────────────────────
header "Live processes with ${VARNAME} in their environment"
own_procs=0
found_procs=0

for environ_file in /proc/*/environ; do
    pid="${environ_file#/proc/}"
    pid="${pid%/environ}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ -r "$environ_file" ]] || continue   # skip other users' processes silently

    own_procs=1
    value=$(tr '\0' '\n' < "$environ_file" 2>/dev/null | grep "^${VARNAME}=" || true)
    if [[ -n "$value" ]]; then
        comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "?")
        echo -e "  ${GRN}✔ PID ${pid} (${comm})${RST}"
        echo -e "    ${YEL}${value}${RST}"
        FOUND=1
        found_procs=1
    fi
done

if [[ $own_procs -eq 0 ]]; then
    echo -e "  ${DIM}(no process environments readable without root)${RST}"
    SKIPPED=1
elif [[ $found_procs -eq 0 ]]; then
    echo -e "  ${DIM}(none of your readable processes have ${VARNAME} set)${RST}"
fi

# ── 8. Specific PID (--pid) ────────────────────────────────────────────────────
if [[ -n "$TARGET_PID" ]]; then
    header "Environment of PID ${TARGET_PID}"
    environ_file="/proc/${TARGET_PID}/environ"
    if [[ ! -e "$environ_file" ]]; then
        echo -e "  ${RED}PID ${TARGET_PID} does not exist.${RST}"
    elif [[ ! -r "$environ_file" ]]; then
        skip_msg "$environ_file (need root or same user)"
    else
        value=$(tr '\0' '\n' < "$environ_file" 2>/dev/null | grep "^${VARNAME}=" || true)
        if [[ -n "$value" ]]; then
            echo -e "  ${GRN}✔ ${value}${RST}"
            FOUND=1
        else
            echo -e "  ${DIM}${VARNAME} not set in PID ${TARGET_PID}.${RST}"
        fi
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLD}────────────────────────────────────${RST}"
if [[ $FOUND -eq 1 ]]; then
    echo -e "${GRN}${BLD}Found! See matches above.${RST}"
else
    echo -e "${RED}${BLD}${VARNAME} was not found in any readable location.${RST}"
fi
if [[ $SKIPPED -eq 1 ]]; then
    echo -e "${DIM}Some locations were skipped (not readable as current user).${RST}"
    echo -e "${DIM}Re-run with sudo for full coverage.${RST}"
fi
