#!/bin/bash
# =============================================================================
# Nagios Service Control Script - PRODUCTION (RHEL)
# Usage   : sudo bash nagios_restart_prod.sh
# Flow    : Pre-flight → Menu → User picks action → Execute
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

LOGFILE="/var/log/nagios_control_prod_$(date +%Y%m%d_%H%M%S).log"
SERVICES_STOP=(nagios npcd mysqld httpd crond)
SERVICES_START=(crond httpd mysqld npcd nagios)

# =============================================================================
# HELPERS
# =============================================================================
log() { echo -e "$1" | tee -a "$LOGFILE"; }

divider() {
    log ""
    log "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BOLD}${CYAN}  $1${NC}"
    log "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}[ERROR] Must be run as root. Use: sudo bash $0${NC}"
        exit 1
    fi
}

is_installed() { systemctl cat "$1" &>/dev/null; }

# =============================================================================
# SERVICE ACTIONS
# =============================================================================
run_status() {
    local svc=$1
    if ! is_installed "$svc"; then
        log "  ${BLUE}[SKIP]    ${svc} — not installed on this host${NC}"
        return
    fi
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "active" ]]; then
        log "  ${GREEN}[ACTIVE]  ${svc}${NC}"
    else
        log "  ${RED}[${state^^}]$(printf '%*s' $((9-${#state})) '') ${svc}${NC}"
    fi
}

run_stop() {
    local svc=$1
    if ! is_installed "$svc"; then
        log "  ${BLUE}[SKIP]    ${svc} — not installed, skipping stop${NC}"
        return
    fi
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" != "active" ]]; then
        log "  ${YELLOW}[ALREADY STOPPED] ${svc}${NC}"
        return
    fi
    log "  ${YELLOW}Stopping ${svc}...${NC}"
    systemctl stop "$svc" >> "$LOGFILE" 2>&1
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" != "active" ]]; then
        log "  ${GREEN}[STOPPED] ${svc}${NC}"
    else
        log "  ${RED}[WARN]    ${svc} may still be running — check manually${NC}"
    fi
}

run_start() {
    local svc=$1
    if ! is_installed "$svc"; then
        log "  ${BLUE}[SKIP]    ${svc} — not installed, skipping start${NC}"
        return
    fi
    log "  ${YELLOW}Starting ${svc}...${NC}"
    systemctl start "$svc" >> "$LOGFILE" 2>&1
    sleep 1
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "active" ]]; then
        log "  ${GREEN}[STARTED] ${svc}${NC}"
    else
        log "  ${RED}[FAILED]  ${svc} — run: systemctl status ${svc}${NC}"
        journalctl -u "$svc" -n 10 --no-pager 2>/dev/null | while IFS= read -r line; do
            log "             ${RED}${line}${NC}"
        done
    fi
}

# =============================================================================
# BULK ACTIONS
# =============================================================================
do_status_all() {
    divider "SERVICE STATUS — PRODUCTION"
    for svc in crond httpd mysqld npcd nagios; do
        run_status "$svc"
    done
}

do_stop_all() {
    divider "STOPPING ALL SERVICES — PRODUCTION"
    log "  ${YELLOW}Stop order: nagios → npcd → mysqld → httpd → crond${NC}"
    log ""
    for svc in "${SERVICES_STOP[@]}"; do
        run_stop "$svc"
    done
    log ""
    log "  ${BOLD}Post-stop verification:${NC}"
    for svc in crond httpd mysqld npcd nagios; do
        run_status "$svc"
    done
}

do_start_all() {
    divider "STARTING ALL SERVICES — PRODUCTION"
    log "  ${YELLOW}Start order: crond → httpd → mysqld → npcd → nagios${NC}"
    log ""
    for svc in "${SERVICES_START[@]}"; do
        run_start "$svc"
    done
    log ""
    log "  ${BOLD}Post-start verification:${NC}"
    for svc in crond httpd mysqld npcd nagios; do
        run_status "$svc"
    done
}

do_restart_all() {
    divider "RESTARTING ALL SERVICES — PRODUCTION"
    log "  ${YELLOW}Phase 1 — Stopping in order: nagios → npcd → mysqld → httpd → crond${NC}"
    log ""
    for svc in "${SERVICES_STOP[@]}"; do
        run_stop "$svc"
    done
    log ""
    log "  ${YELLOW}Waiting 2 seconds before starting...${NC}"
    sleep 2
    log ""
    log "  ${YELLOW}Phase 2 — Starting in order: crond → httpd → mysqld → npcd → nagios${NC}"
    log ""
    for svc in "${SERVICES_START[@]}"; do
        run_start "$svc"
    done
    log ""
    log "  ${BOLD}Final status after restart:${NC}"
    for svc in crond httpd mysqld npcd nagios; do
        run_status "$svc"
    done
}

# =============================================================================
# PRE-FLIGHT
# =============================================================================
preflight() {
    divider "PRE-FLIGHT CHECK"
    log "  OS       : $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
    log "  Hostname : $(hostname)"
    log "  Kernel   : $(uname -r)"
    log "  Time     : $(date)"
    log ""
    log "  ${BOLD}Service availability on this host:${NC}"
    for svc in crond httpd mysqld npcd nagios; do
        if is_installed "$svc"; then
            log "  ${GREEN}[FOUND]   ${svc}${NC}"
        else
            log "  ${BLUE}[MISSING] ${svc} — will be skipped${NC}"
        fi
    done
}

# =============================================================================
# INTERACTIVE MENU
# =============================================================================
show_menu() {
    echo ""
    echo -e "${BOLD}${MAGENTA}  ┌─────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${MAGENTA}  │       NAGIOS SERVICE CONTROL MENU           │${NC}"
    echo -e "${BOLD}${MAGENTA}  │              PRODUCTION                     │${NC}"
    echo -e "${BOLD}${MAGENTA}  ├─────────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}${MAGENTA}  │  1.  Status   — show current service status │${NC}"
    echo -e "${BOLD}${MAGENTA}  │  2.  Stop     — stop all services           │${NC}"
    echo -e "${BOLD}${MAGENTA}  │  3.  Start    — start all services          │${NC}"
    echo -e "${BOLD}${MAGENTA}  │  4.  Restart  — stop then start all         │${NC}"
    echo -e "${BOLD}${MAGENTA}  │  5.  Exit                                   │${NC}"
    echo -e "${BOLD}${MAGENTA}  └─────────────────────────────────────────────┘${NC}"
    echo ""
    echo -ne "  ${BOLD}What would you like to do? [1-5]: ${NC}"
}

interactive_menu() {
    while true; do
        show_menu
        read -r choice
        echo ""
        case "$choice" in
            1)
                do_status_all
                ;;
            2)
                echo -e "  ${RED}⚠  WARNING — This is a PRODUCTION server.${NC}"
                echo -ne "  ${RED}   Are you sure you want to STOP all services? [y/N]: ${NC}"
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    do_stop_all
                else
                    echo -e "  ${BLUE}Cancelled. No changes made.${NC}"
                fi
                ;;
            3)
                echo -e "  ${YELLOW}⚠  PRODUCTION — Are you sure you want to START all services? [y/N]: ${NC}"
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    do_start_all
                else
                    echo -e "  ${BLUE}Cancelled. No changes made.${NC}"
                fi
                ;;
            4)
                echo -e "  ${RED}⚠  WARNING — This is a PRODUCTION server.${NC}"
                echo -ne "  ${RED}   Are you sure you want to RESTART all services? [y/N]: ${NC}"
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    do_restart_all
                else
                    echo -e "  ${BLUE}Cancelled. No changes made.${NC}"
                fi
                ;;
            5)
                echo -e "  ${GREEN}Exiting. Full log saved: ${LOGFILE}${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "  ${RED}Invalid choice '${choice}'. Please enter a number between 1 and 5.${NC}"
                ;;
        esac
        echo ""
        echo -e "  ${CYAN}─────────────────────────────────────────────────${NC}"
        echo -ne "  ${BOLD}Press ENTER to return to menu...${NC}"
        read -r
    done
}

# =============================================================================
# MAIN — Pre-flight first, then straight to menu
# =============================================================================
check_root

log ""
log "${BOLD}${CYAN}  ███████████████████████████████████████████████████████████${NC}"
log "${BOLD}${CYAN}  Nagios Service Control — PRODUCTION                       ${NC}"
log "${BOLD}${CYAN}  ███████████████████████████████████████████████████████████${NC}"
log ""
log "  Log file : ${LOGFILE}"

preflight

# Go straight to menu — no automatic restart
interactive_menu
