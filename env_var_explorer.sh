#!/usr/bin/env bash
# find_env_var.sh — locate where an environment variable is defined.
# Works without root; skips unreadable locations gracefully.
#
# Usage: ./find_env_var.sh VARNAME
#        ./find_env_var.sh --help

shopt -s nullglob

RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
DIM='\033[2m'
RST='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] VARNAME

Search for where an environment variable is defined across:
  - System-wide shell init  (/etc/bashrc, /etc/profile, etc.)
  - User shell init files   (~/.bashrc, ~/.bash_profile, etc.)
  - PAM environment         (/etc/security/)
  - systemd unit files      (Environment= and EnvironmentFile= directives,
                             with recursive scanning of referenced files)
  - Sysconfig / app dirs    (/etc/sysconfig/, /etc/default/, /etc/conf.d/)
  - Live processes          (/proc/*/environ, own user only without root)
  - Running Docker containers (via docker inspect)

Unreadable locations are skipped with a notice; re-run with sudo for full coverage.

Options:
  -h, --help          Show this help and exit
  --skip-units        Skip scanning systemd unit files
  --skip-docker       Skip scanning running Docker containers

Example:
  $(basename "$0") AIRFLOW_HOME
  $(basename "$0") --skip-units AIRFLOW_HOME
EOF
}

ARGS=$(getopt -o 'h' --long 'help,skip-units,skip-docker' -n "$(basename "$0")" -- "$@")
if [[ $? -ne 0 ]]; then usage; exit 1; fi
eval set -- "$ARGS"

SKIP_UNITS=0
SKIP_DOCKER=0

while true; do
    case "$1" in
        -h | --help)        usage; exit 0 ;;
        --skip-units)       SKIP_UNITS=1;  shift ;;
        --skip-docker)      SKIP_DOCKER=1; shift ;;
        --)                 shift; break ;;  # End of options
        *)                  echo "Internal error!"; exit 1 ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo "Error: VARNAME required."
    usage
    exit 1
fi

VARNAME="$1"
FOUND=0
SKIPPED=0

# Regex for shell-syntax files
RE_SHELL="(^|[[:space:]]|;)export[[:space:]]+${VARNAME}[=[:space:]]|^[[:space:]]*${VARNAME}[[:space:]]*="
# Regex for YAML/Docker Compose
# RE_YAML="^[[:space:]]*-?[[:space:]]*${VARNAME}[[:space:]]*[:=]"

header()   { echo -e "\n${BLD}${CYN}=== $1 ===${RST}"; }
skip_msg() { echo -e "  ${DIM}(skipped — not readable: $1)${RST}"; SKIPPED=1; }
clear_progress() { printf "\r%-60s\r" " "; }   # overwrite progress line with spaces

search_file() {
    local file="$1" re="${2:-$RE_SHELL}" ref="$3"
    [[ -e "$file" ]] || return 0
    if [[ ! -r "$file" ]]; then skip_msg "$file"; return 0; fi
    local matches
    matches=$(grep -nE "$re" "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        echo -e "  ${GRN}✔ ${ref}${ref:+ references }${file}${RST}"
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

# ── 1. System-wide shell init ──────────────────────────────────────────────────
header "System-wide shell init"
search_file /etc/bashrc
search_file /etc/bash.bashrc
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
search_dir  /etc/security 1

# ── 4. systemd units ──────────────────────────────────────────────────────────
header "systemd unit files"
if [[ $SKIP_UNITS -ne 1 ]]; then
i=0
for unit_dir in /etc/systemd/system /usr/lib/systemd/system /run/systemd/system; do
    [[ -d "$unit_dir" ]] || continue
    if [[ ! -r "$unit_dir" ]]; then skip_msg "$unit_dir"; continue; fi
    while IFS= read -r -d '' f; do
        [[ -r "$f" ]] || continue
        printf "\r  ${DIM}Scanning unit %d: %-50s${RST}\r" "$((++i))" "$(basename "$f")"

        matches=$(grep -niE "^\s*(Environment|EnvironmentFile).*${VARNAME}" "$f" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            clear_progress
            echo -e "  ${GRN}✔ ${f}${RST}"
            while IFS= read -r line; do
                echo -e "    ${YEL}${line}${RST}"
            done <<< "$matches"
            FOUND=1
        fi

        # Scan files referenced by EnvironmentFile= regardless of whether VARNAME
        # was found above — the unit itself might not mention VARNAME but its
        # EnvironmentFile might.
        while IFS= read -r env_file_line; do
            # Strip the directive name, handle optional leading minus (ignore-errors marker)
            env_file=$(echo "$env_file_line" | sed 's/^\s*EnvironmentFile\s*=\s*-\?//')
            # Skip empty or obviously invalid values
            [[ -z "$env_file" || "$env_file" == *'$'* ]] && continue
            if [[ -e "$env_file" ]]; then
                clear_progress
                search_file "$env_file" "$RE_SHELL" "$f"
            fi
        done < <(grep -iE "^\s*EnvironmentFile\s*=" "$f" 2>/dev/null || true)

    done < <(find "$unit_dir" -maxdepth 2 -type f -print0 2>/dev/null)
done
clear_progress
fi  # --skip-units

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
    [[ "$pid" != "$$" ]] || continue  # script process
    [[ -r "$environ_file" ]] || continue
    own_procs=1
    value=$(tr '\0' '\n' < "$environ_file" 2>/dev/null | grep "^${VARNAME}=" || true)
    if [[ -n "$value" ]]; then
        comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "?")
        ppid=$(awk '/^PPid:/{print $2}' "/proc/${pid}/status" 2>/dev/null || echo "?")
        pcomm=$(cat "/proc/${ppid}/comm" 2>/dev/null || echo "?")
        (( pid = $PPID )) && this_proc=true || unset this_proc
        echo -e "  ${GRN}✔ PID ${pid} (${comm})  ←  PPID ${ppid} (${pcomm})${DIM}${this_proc:+this}${RST}"
        echo -e "    ${YEL}${value}${RST}"
        FOUND=1; found_procs=1
    fi
done
if   [[ $own_procs -eq 0 ]];   then echo -e "  ${DIM}(no process environments readable without root)${RST}"; SKIPPED=1
elif [[ $found_procs -eq 0 ]]; then echo -e "  ${DIM}(none of your readable processes have ${VARNAME} set)${RST}"
fi

# ── 7. Running Docker containers ──────────────────────────────────────────────
header "Running Docker containers"
if [[ $SKIP_DOCKER -eq 1 ]]; then
    echo -e "  ${DIM}(skipped via --skip-docker)${RST}"
elif ! command -v docker &>/dev/null; then
    echo -e "  ${DIM}(docker not found in PATH, skipping)${RST}"
elif ! docker info &>/dev/null 2>&1; then
    echo -e "  ${DIM}(docker daemon not reachable without root, skipping)${RST}"
    SKIPPED=1
else
    found_containers=0
    while IFS= read -r container_id; do
        [[ -z "$container_id" ]] && continue
        name=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||')
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
