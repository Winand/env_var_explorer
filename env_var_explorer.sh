#!/usr/bin/env bash
# find_env_var.sh — locate where an environment variable is defined
# Works without root; skips unreadable locations gracefully.
#
# Usage:   ./find_env_var.sh VARNAME [--pid PID] [--quick]
# Example: ./find_env_var.sh AIRFLOW_HOME
#          ./find_env_var.sh AIRFLOW_HOME --pid 1234
#          ./find_env_var.sh AIRFLOW_HOME --pid 1234 --quick

shopt -s nullglob   # globs that match nothing expand to nothing, not literal string

RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
DIM='\033[2m'
RST='\033[0m'

usage() {
    echo "Usage: $0 VARNAME [--pid PID] [--quick]"
    echo "  VARNAME   environment variable to search for (e.g. AIRFLOW_HOME)"
    echo "  --pid     also inspect /proc/<pid>/environ for a specific process"
    echo "  --quick   with --pid: show that PID first, then skip the rest of the search"
    exit 1
}

[[ $# -lt 1 ]] && usage

VARNAME="$1"
TARGET_PID=""
QUICK=0
FOUND=0
SKIPPED=0

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pid)   TARGET_PID="$2"; shift 2 ;;
        --quick) QUICK=1; shift ;;
        *)       echo "Unknown argument: $1"; usage ;;
    esac
done

[[ $QUICK -eq 1 && -z "$TARGET_PID" ]] && { echo "--quick requires --pid"; usage; }

header()   { echo -e "\n${BLD}${CYN}=== $1 ===${RST}"; }
skip_msg() { echo -e "  ${DIM}(skipped — not readable: $1)${RST}"; SKIPPED=1; }

# ── File search helpers ────────────────────────────────────────────────────────

# Regex for shell-style files: "export VAR=..." or "VAR=..."
RE_SHELL="(^|[[:space:]]|;)export[[:space:]]+${VARNAME}[=[:space:]]|^[[:space:]]*${VARNAME}[[:space:]]*="

# Regex for YAML/Docker Compose: "- VAR=..." or "VAR: ..." (with any indentation)
RE_YAML="^[[:space:]]*-?[[:space:]]*${VARNAME}[[:space:]]*[:=]"

search_file() {
    local file="$1"
    local re="${2:-$RE_SHELL}"
    [[ -e "$file" ]] || return 0
    if [[ ! -r "$file" ]]; then skip_msg "$file"; return 0; fi
    local matches
    matches=$(grep -nE "$re" "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        echo -e "  ${GRN}✔ ${file}${RST}"
        while IFS= read -r line; do
            echo -e "    ${YEL}${line}${RST}"
        done <<< "$matches"
        FOUND=1
    fi
}

search_dir() {
    local dir="$1" depth="${2:-1}" re="${3:-$RE_SHELL}"
    [[ -d "$dir" ]] || return 0
    if [[ ! -r "$dir" ]]; then skip_msg "$dir"; return 0; fi
    while IFS= read -r -d '' f; do
        search_file "$f" "$re"
    done < <(find "$dir" -maxdepth "$depth" -type f \
              \( -name "*.sh" -o -name "*.conf" -o -name "*.env" -o -name "profile" \) \
              -print0 2>/dev/null)
}

# ── PID helper (used early if --pid given, and again in section 7) ─────────────

check_pid() {
    local pid="$1"
    local environ_file="/proc/${pid}/environ"
    if [[ ! -e "$environ_file" ]]; then
        echo -e "  ${RED}PID ${pid} does not exist.${RST}"; return
    fi
    if [[ ! -r "$environ_file" ]]; then
        skip_msg "$environ_file (need root or same user)"; return
    fi
    local value
    value=$(tr '\0' '\n' < "$environ_file" 2>/dev/null | grep "^${VARNAME}=" || true)
    local comm
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "?")
    if [[ -n "$value" ]]; then
        echo -e "  ${GRN}✔ PID ${pid} (${comm})${RST}"
        echo -e "    ${YEL}${value}${RST}"
        FOUND=1
    else
        echo -e "  ${DIM}${VARNAME} not set in PID ${pid} (${comm}).${RST}"
    fi
}

# ── If --pid given, check it first (before any disk search) ───────────────────

if [[ -n "$TARGET_PID" ]]; then
    header "Environment of PID ${TARGET_PID} (checked first)"
    check_pid "$TARGET_PID"
    if [[ $QUICK -eq 1 ]]; then
        echo -e "\n${DIM}(--quick: skipping full filesystem search)${RST}"
        echo ""
        [[ $FOUND -eq 1 ]] \
            && echo -e "${GRN}${BLD}Found!${RST}" \
            || echo -e "${RED}${BLD}${VARNAME} not found in PID ${TARGET_PID}.${RST}"
        exit 0
    fi
fi

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

# ── 4. systemd units ──────────────────────────────────────────────────────────
header "systemd unit files"
i=0
for unit_dir in /etc/systemd/system /usr/lib/systemd/system /run/systemd/system; do
    [[ -d "$unit_dir" ]] || continue
    if [[ ! -r "$unit_dir" ]]; then skip_msg "$unit_dir"; continue; fi
    while IFS= read -r -d '' f; do
        [[ -r "$f" ]] || continue
        printf "\r  ${DIM}Scanned $((i++)) units${RST}"
        # Single grep pass: collect lines, print only if non-empty
        matches=$(grep -niE "^\s*(Environment|EnvironmentFile).*${VARNAME}" "$f" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            echo -e "\r  ${GRN}✔ ${f}${RST}"
            while IFS= read -r line; do
                echo -e "    ${YEL}${line}${RST}"
            done <<< "$matches"
            FOUND=1
        fi
    done < <(find "$unit_dir" -maxdepth 2 -type f -print0 2>/dev/null)
done
printf "\r                    "  # clear last "Scanned N units" message

# ── 5. Common application / sysconfig dirs ────────────────────────────────────
header "Application / sysconfig files"
search_dir /etc/sysconfig     1
search_dir /etc/default       1
search_dir /etc/conf.d        1
search_dir /etc/environment.d 1

# ── 6. Live processes (own user) ──────────────────────────────────────────────
header "Live processes with ${VARNAME} in their environment"
own_procs=0
found_procs=0

for environ_file in /proc/*/environ; do
    pid="${environ_file#/proc/}"; pid="${pid%/environ}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # Skip the PID we already checked above to avoid duplicate output
    [[ -n "$TARGET_PID" && "$pid" == "$TARGET_PID" ]] && continue
    [[ -r "$environ_file" ]] || continue

    own_procs=1
    value=$(tr '\0' '\n' < "$environ_file" 2>/dev/null | grep "^${VARNAME}=" || true)
    if [[ -n "$value" ]]; then
        comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "?")
        echo -e "  ${GRN}✔ PID ${pid} (${comm})${RST}"
        echo -e "    ${YEL}${value}${RST}"
        FOUND=1; found_procs=1
    fi
done

if   [[ $own_procs -eq 0 ]];   then echo -e "  ${DIM}(no process environments readable without root)${RST}"; SKIPPED=1
elif [[ $found_procs -eq 0 ]]; then echo -e "  ${DIM}(none of your readable processes have ${VARNAME} set)${RST}"
fi

# ── 7. Running Docker containers ──────────────────────────────────────────────
header "Running Docker containers"
if ! command -v docker &>/dev/null; then
    echo -e "  ${DIM}(docker not found in PATH, skipping)${RST}"
elif ! docker info &>/dev/null 2>&1; then
    echo -e "  ${DIM}(docker daemon not reachable without root, skipping)${RST}"
    SKIPPED=1
else
    found_containers=0
    while IFS= read -r container_id; do
        [[ -z "$container_id" ]] && continue
        name=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||')
        # docker inspect returns env as ["VAR=val", ...] — grep is enough
        value=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
                "$container_id" 2>/dev/null | grep "^${VARNAME}=" || true)
        if [[ -n "$value" ]]; then
            echo -e "  ${GRN}✔ container ${container_id} (${name})${RST}"
            echo -e "    ${YEL}${value}${RST}"
            FOUND=1; found_containers=1
        fi
    done < <(docker ps -q 2>/dev/null)
    [[ $found_containers -eq 0 ]] && echo -e "  ${DIM}(no running containers have ${VARNAME} set)${RST}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
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
