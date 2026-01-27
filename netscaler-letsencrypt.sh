#!/bin/sh
#===============================================================================
# NetScaler Let's Encrypt Certificate Manager
#
# Run this script directly on the NetScaler appliance.
#
# This script:
# 1. Requests a Let's Encrypt certificate using acme.sh with DNS challenge
# 2. Installs the certificate on NetScaler
# 3. Binds the certificate to selected SSL virtual servers (LB/Gateway)
#
# Requirements:
# - acme.sh installed on NetScaler (in /var/nsconfig/acme or /root/.acme.sh)
# - Shell access to NetScaler
#===============================================================================

# Configuration
SSL_DIR="/nsconfig/ssl"
ACME_HOME="${ACME_HOME:-/var/nsconfig/acme}"
CERT_KEY_BITS="${CERT_KEY_BITS:-2048}"
ACME_SERVER="letsencrypt"  # Use Let's Encrypt (not ZeroSSL)

# NetScaler credentials (set at startup)
NS_IP=""
NS_USER="nsroot"
NS_PASS=""

# Colors (NetScaler shell supports basic ANSI)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" >&2 "$1"
}

# Find nscli location
NSCLI=""
find_nscli() {
    # Check common locations
    for path in /netscaler/nscli /var/nsconfig/nscli /usr/local/bin/nscli; do
        if [ -x "$path" ]; then
            NSCLI="$path"
            return 0
        fi
    done
    # Try PATH
    if command -v nscli >/dev/null 2>&1; then
        NSCLI="nscli"
        return 0
    fi
    return 1
}

# Run NetScaler CLI command
nscli_cmd() {
    $NSCLI -U "${NS_IP}:${NS_USER}:${NS_PASS}" "$*"
}

# Check if running on NetScaler
check_netscaler() {
    # Check for NetScaler-specific files/directories
    if [ ! -d /nsconfig ] && [ ! -d /var/nsconfig ]; then
        log_error "This script must be run on a NetScaler appliance"
        exit 1
    fi

    # Find nscli
    if ! find_nscli; then
        log_error "Cannot find nscli command"
        log_info "Checking common locations..."
        ls -la /netscaler/nscli /var/nsconfig/nscli /usr/local/bin/nscli 2>/dev/null
        exit 1
    fi

    log_info "Found nscli at: $NSCLI"
}

# Get NetScaler credentials for CLI access
setup_credentials() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  NETSCALER CLI CREDENTIALS${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "\n"

    # Default to localhost since we're running on the NetScaler
    NS_IP="127.0.0.1"

    printf "NetScaler IP [$NS_IP]: "
    read input_ip
    if [ -n "$input_ip" ]; then
        NS_IP="$input_ip"
    fi

    printf "Username [$NS_USER]: "
    read input_user
    if [ -n "$input_user" ]; then
        NS_USER="$input_user"
    fi

    # Use stty to hide password input
    stty -echo 2>/dev/null
    printf "Password: "
    read NS_PASS
    stty echo 2>/dev/null
    printf "\n"

    if [ -z "$NS_PASS" ]; then
        log_error "Password is required"
        exit 1
    fi

    # Test credentials
    log_info "Testing credentials..."
    test_output=$(nscli_cmd "show ns version" 2>&1)

    if echo "$test_output" | grep -q "NetScaler"; then
        log_success "Credentials verified"
    else
        log_error "Failed to authenticate: $test_output"
        exit 1
    fi
}

# Check for acme.sh
check_acme() {
    if [ -f "$ACME_HOME/acme.sh" ]; then
        return 0
    elif [ -f "/root/.acme.sh/acme.sh" ]; then
        ACME_HOME="/root/.acme.sh"
        return 0
    elif [ -f "/var/nsconfig/.acme.sh/acme.sh" ]; then
        ACME_HOME="/var/nsconfig/.acme.sh"
        return 0
    else
        return 1
    fi
}

install_acme() {
    log_info "Installing acme.sh to $ACME_HOME..."

    mkdir -p "$ACME_HOME"
    cd /tmp

    # Download acme.sh
    if command -v curl >/dev/null 2>&1; then
        curl -sL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o acme.tar.gz
    elif command -v fetch >/dev/null 2>&1; then
        fetch -q -o acme.tar.gz https://github.com/acmesh-official/acme.sh/archive/master.tar.gz
    else
        log_error "Neither curl nor fetch available. Please install acme.sh manually."
        return 1
    fi

    tar -xzf acme.tar.gz
    cd acme.sh-master
    ./acme.sh --install --home "$ACME_HOME" --nocron
    # Set Let's Encrypt as default CA
    $ACME_HOME/acme.sh --set-default-ca --server letsencrypt
    cd /tmp
    rm -rf acme.sh-master acme.tar.gz

    if [ -f "$ACME_HOME/acme.sh" ]; then
        log_success "acme.sh installed successfully"
        return 0
    else
        log_error "Failed to install acme.sh"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Certificate Functions
#-------------------------------------------------------------------------------
issue_certificate() {
    domain="$1"
    san_domains="$2"

    log_info "Requesting certificate for: $domain"

    # Build acme.sh command
    acme_cmd="$ACME_HOME/acme.sh --issue --dns -d $domain --keylength $CERT_KEY_BITS --yes-I-know-dns-manual-mode-enough-go-ahead-please"

    # Add SAN domains if provided
    if [ -n "$san_domains" ]; then
        log_info "With SAN domains: $san_domains"
        # Split by comma and add each domain
        echo "$san_domains" | tr ',' '\n' | while read san; do
            san=$(echo "$san" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$san" ]; then
                acme_cmd="$acme_cmd -d $san"
            fi
        done
    fi

    printf "\n"
    log_warn "Manual DNS challenge mode"
    printf "${CYAN}You will need to create TXT record(s) for domain validation.${NC}\n"
    printf "\n"

    # First run - get the DNS records needed
    $ACME_HOME/acme.sh --issue --dns -d "$domain" --keylength "$CERT_KEY_BITS" --server "$ACME_SERVER" --yes-I-know-dns-manual-mode-enough-go-ahead-please 2>&1 | tee /tmp/acme_output.txt

    # Check if we need to add DNS records
    if grep -q "TXT value:" /tmp/acme_output.txt; then
        printf "\n"
        printf "${YELLOW}===========================================${NC}\n"
        printf "${YELLOW}  DNS TXT RECORDS REQUIRED${NC}\n"
        printf "${YELLOW}===========================================${NC}\n"
        printf "\n"
        grep -E "(Domain:|TXT value:)" /tmp/acme_output.txt
        printf "\n"
        printf "${YELLOW}Add the TXT record(s) to your DNS.${NC}\n"
        printf "${YELLOW}Wait for DNS propagation (1-5 minutes).${NC}\n"
        printf "\n"
        printf "Press ENTER when DNS records are in place..."
        read dummy
        printf "\n"

        # Second run - verify and complete
        log_info "Verifying DNS and completing issuance..."
        $ACME_HOME/acme.sh --renew -d "$domain" --server "$ACME_SERVER" --yes-I-know-dns-manual-mode-enough-go-ahead-please --force
    fi

    rm -f /tmp/acme_output.txt

    # Check if certificate was issued (search all possible locations)
    cert_dir=$(get_cert_dir "$domain")

    if [ -n "$cert_dir" ] && [ -f "$cert_dir/fullchain.cer" ]; then
        log_success "Certificate issued successfully"
        log_info "Certificate location: $cert_dir"
        return 0
    else
        log_error "Certificate issuance failed"
        log_error "Could not find certificate files"
        return 1
    fi
}

get_cert_dir() {
    domain="$1"

    # Check multiple possible locations (ACME_HOME and common acme.sh locations)
    for base_dir in "$ACME_HOME" "/root/.acme.sh" "/var/nsconfig/.acme.sh" "/var/nsconfig/acme"; do
        # Check ECC cert first, then RSA
        for suffix in "_ecc" ""; do
            cert_dir="${base_dir}/${domain}${suffix}"
            if [ -d "$cert_dir" ] && [ -f "$cert_dir/fullchain.cer" ]; then
                echo "$cert_dir"
                return 0
            fi
        done
    done

    return 1
}

install_certificate() {
    certkey_name="$1"
    cert_file="$2"
    key_file="$3"

    log_info "Installing certificate: $certkey_name"

    # Copy files to SSL directory
    cert_dest="$SSL_DIR/${certkey_name}.cer"
    key_dest="$SSL_DIR/${certkey_name}.key"

    cp "$cert_file" "$cert_dest"
    cp "$key_file" "$key_dest"
    chmod 600 "$key_dest"

    log_success "Files copied to $SSL_DIR"

    # Try to add, if it exists then update
    log_info "Creating new certificate-key pair..."
    add_result=$(nscli_cmd "add ssl certkey $certkey_name -cert $cert_dest -key $key_dest" 2>&1)

    if echo "$add_result" | grep -qi "already exists"; then
        log_info "Certificate exists, updating..."
        update_result=$(nscli_cmd "update ssl certkey $certkey_name -cert $cert_dest -key $key_dest -nodomaincheck" 2>&1)
        if echo "$update_result" | grep -qi "error"; then
            log_error "Failed to update certificate: $update_result"
            return 1
        fi
        log_success "Certificate updated: $certkey_name"
    elif echo "$add_result" | grep -qi "error"; then
        log_error "Failed to add certificate: $add_result"
        return 1
    else
        log_success "Certificate installed: $certkey_name"
    fi

    return 0
}

#-------------------------------------------------------------------------------
# Virtual Server Functions
#-------------------------------------------------------------------------------
get_lb_ssl_vservers() {
    # Get LB vservers with SSL or SSL_TCP protocol
    # Format: 1)      vsrv_StoreFront (10.10.114.233:443) - SSL       Type: ADDRESS
    nscli_cmd "show lb vserver" 2>/dev/null | grep -E "^[0-9]+\).*- SSL" | awk '{print $2}'
}

get_vpn_vservers() {
    # Get Gateway/VPN vservers
    # Format: 1)      vpn_vserver_name (IP:port) - SSL       Type: ...
    nscli_cmd "show vpn vserver" 2>/dev/null | grep -E "^[0-9]+\)" | awk '{print $2}'
}

get_cs_ssl_vservers() {
    # Get Content Switching vservers with SSL
    nscli_cmd "show cs vserver" 2>/dev/null | grep -E "^[0-9]+\).*- SSL" | awk '{print $2}'
}

get_vserver_cert() {
    vserver="$1"
    # Format: 1)      CertKey Name: Store-2025        Server Certificate
    nscli_cmd "show ssl vserver $vserver" 2>/dev/null | grep "CertKey Name:" | head -1 | sed 's/.*CertKey Name: *//' | awk '{print $1}'
}

bind_certificate() {
    vserver="$1"
    certkey="$2"
    vserver_type="$3"

    log_info "Binding $certkey to $vserver..."

    # Check for existing binding
    existing_cert=$(get_vserver_cert "$vserver")

    if [ -n "$existing_cert" ] && [ "$existing_cert" != "$certkey" ]; then
        log_warn "Existing certificate bound: $existing_cert"
        printf "  Unbind existing and bind new? (y/n): "
        read confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            log_info "Unbinding $existing_cert..."
            unbind_result=$(nscli_cmd "unbind ssl vserver $vserver -certkeyname $existing_cert" 2>&1)
            if echo "$unbind_result" | grep -qi "error"; then
                log_warn "Unbind warning: $unbind_result"
            fi
        else
            log_info "Skipped"
            return 0
        fi
    fi

    bind_result=$(nscli_cmd "bind ssl vserver $vserver -certkeyname $certkey" 2>&1)

    if echo "$bind_result" | grep -qi "Done"; then
        log_success "Certificate bound to $vserver"
        return 0
    elif echo "$bind_result" | grep -qi "error"; then
        log_error "Failed to bind: $bind_result"
        return 1
    else
        log_success "Certificate bound to $vserver"
        return 0
    fi
}

save_config() {
    log_info "Saving configuration..."
    nscli_cmd "save config"
    log_success "Configuration saved"
}

#-------------------------------------------------------------------------------
# Menu Functions
#-------------------------------------------------------------------------------
show_header() {
    clear
    printf "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║     NetScaler Let's Encrypt Certificate Manager           ║${NC}\n"
    printf "${GREEN}║     Direct CLI Version                                    ║${NC}\n"
    printf "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
}

show_main_menu() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  MAIN MENU${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "\n"
    printf "  1) Request new certificate & bind\n"
    printf "  2) Install existing certificate & bind\n"
    printf "  3) Renew certificate\n"
    printf "  4) List SSL virtual servers\n"
    printf "  5) List installed certificates\n"
    printf "  0) Exit\n"
    printf "\n"
    printf "Select option: "
}

select_vservers_menu() {
    certkey_name="$1"

    printf "\n"
    log_info "Fetching virtual servers..."
    printf "\n"

    # Build list of all vservers
    vserver_list=""
    vserver_count=0

    # LB SSL vservers
    printf "${CYAN}Load Balancer SSL Virtual Servers:${NC}\n"
    for vs in $(get_lb_ssl_vservers); do
        if [ -n "$vs" ]; then
            vserver_count=$((vserver_count + 1))
            vserver_list="$vserver_list$vserver_count:LB:$vs\n"
            cert=$(get_vserver_cert "$vs")
            printf "  %d) [LB] %s" "$vserver_count" "$vs"
            if [ -n "$cert" ]; then
                printf " (Cert: %s)" "$cert"
            fi
            printf "\n"
        fi
    done

    # VPN/Gateway vservers
    printf "\n${CYAN}Gateway/VPN Virtual Servers:${NC}\n"
    for vs in $(get_vpn_vservers); do
        if [ -n "$vs" ]; then
            vserver_count=$((vserver_count + 1))
            vserver_list="$vserver_list$vserver_count:VPN:$vs\n"
            cert=$(get_vserver_cert "$vs")
            printf "  %d) [Gateway] %s" "$vserver_count" "$vs"
            if [ -n "$cert" ]; then
                printf " (Cert: %s)" "$cert"
            fi
            printf "\n"
        fi
    done

    # Content Switching SSL vservers
    printf "\n${CYAN}Content Switching SSL Virtual Servers:${NC}\n"
    for vs in $(get_cs_ssl_vservers); do
        if [ -n "$vs" ]; then
            vserver_count=$((vserver_count + 1))
            vserver_list="$vserver_list$vserver_count:CS:$vs\n"
            cert=$(get_vserver_cert "$vs")
            printf "  %d) [CS] %s" "$vserver_count" "$vs"
            if [ -n "$cert" ]; then
                printf " (Cert: %s)" "$cert"
            fi
            printf "\n"
        fi
    done

    if [ $vserver_count -eq 0 ]; then
        log_warn "No SSL virtual servers found"
        return 1
    fi

    printf "\n"
    printf "  a) Select ALL\n"
    printf "  0) Done / Skip binding\n"
    printf "\n"
    printf "Enter numbers separated by spaces (e.g., 1 3 5), 'a' for all, or 0 to skip: "
    read selection

    if [ "$selection" = "0" ] || [ -z "$selection" ]; then
        log_info "Skipping certificate binding"
        return 0
    fi

    if [ "$selection" = "a" ] || [ "$selection" = "A" ]; then
        selection=$(seq 1 $vserver_count | tr '\n' ' ')
    fi

    printf "\n"
    log_info "Binding certificate to selected virtual servers..."
    printf "\n"

    for num in $selection; do
        # Find vserver info from list
        vs_info=$(printf "$vserver_list" | grep "^${num}:")
        if [ -n "$vs_info" ]; then
            vs_type=$(echo "$vs_info" | cut -d: -f2)
            vs_name=$(echo "$vs_info" | cut -d: -f3)
            bind_certificate "$vs_name" "$certkey_name" "$vs_type"
        fi
    done

    return 0
}

#-------------------------------------------------------------------------------
# Flow Functions
#-------------------------------------------------------------------------------
new_certificate_flow() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  REQUEST NEW CERTIFICATE${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "\n"

    printf "Primary domain (e.g., www.example.com): "
    read domain

    if [ -z "$domain" ]; then
        log_error "Domain is required"
        return 1
    fi

    printf "Additional SAN domains (comma-separated, or leave empty): "
    read san_domains

    # Generate default certkey name
    default_certkey=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
    printf "Certificate name in NetScaler [%s]: " "$default_certkey"
    read certkey_name
    certkey_name="${certkey_name:-$default_certkey}"

    printf "\n"
    log_info "Summary:"
    printf "  Primary Domain: %s\n" "$domain"
    printf "  SAN Domains: %s\n" "${san_domains:-None}"
    printf "  CertKey Name: %s\n" "$certkey_name"
    printf "\n"
    printf "Proceed? (y/n): "
    read confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Cancelled"
        return 0
    fi

    # Issue certificate
    issue_certificate "$domain" "$san_domains"
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Get cert paths
    cert_dir=$(get_cert_dir "$domain")
    if [ -z "$cert_dir" ]; then
        log_error "Certificate directory not found"
        return 1
    fi

    cert_file="$cert_dir/fullchain.cer"
    key_file="$cert_dir/${domain}.key"

    # Install certificate
    install_certificate "$certkey_name" "$cert_file" "$key_file"
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Select and bind
    select_vservers_menu "$certkey_name"

    # Save config
    save_config

    printf "\n"
    log_success "Certificate deployment complete!"
    printf "\n"
    printf "Press ENTER to continue..."
    read dummy
}

install_certificate_flow() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  INSTALL EXISTING CERTIFICATE${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "\n"

    printf "Path to certificate file (fullchain.pem or .cer): "
    read cert_path

    printf "Path to private key file (.key): "
    read key_path

    printf "Certificate name in NetScaler: "
    read certkey_name

    if [ ! -f "$cert_path" ]; then
        log_error "Certificate file not found: $cert_path"
        return 1
    fi

    if [ ! -f "$key_path" ]; then
        log_error "Key file not found: $key_path"
        return 1
    fi

    if [ -z "$certkey_name" ]; then
        log_error "Certificate name is required"
        return 1
    fi

    # Install certificate
    install_certificate "$certkey_name" "$cert_path" "$key_path"

    # Select and bind
    select_vservers_menu "$certkey_name"

    # Save config
    save_config

    log_success "Certificate installation complete!"
    printf "\nPress ENTER to continue..."
    read dummy
}

renew_certificate_flow() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  RENEW CERTIFICATE${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "\n"

    log_info "Certificates managed by acme.sh:"
    printf "\n"
    $ACME_HOME/acme.sh --list 2>/dev/null

    printf "\n"
    printf "Enter domain to renew: "
    read domain

    if [ -z "$domain" ]; then
        log_error "Domain is required"
        return 1
    fi

    printf "Certificate name in NetScaler to update: "
    read certkey_name

    log_info "Renewing certificate for $domain..."
    $ACME_HOME/acme.sh --renew -d "$domain" --server "$ACME_SERVER" --yes-I-know-dns-manual-mode-enough-go-ahead-please --force

    if [ $? -ne 0 ]; then
        log_error "Renewal failed"
        return 1
    fi

    if [ -n "$certkey_name" ]; then
        cert_dir=$(get_cert_dir "$domain")
        cert_file="$cert_dir/fullchain.cer"
        key_file="$cert_dir/${domain}.key"

        install_certificate "$certkey_name" "$cert_file" "$key_file"
        save_config

        log_success "Certificate renewed and updated!"
    else
        log_success "Certificate renewed. Use 'Install existing certificate' to update NetScaler."
    fi

    printf "\nPress ENTER to continue..."
    read dummy
}

list_vservers_flow() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  SSL VIRTUAL SERVERS${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "\n"

    printf "${CYAN}Load Balancer SSL Virtual Servers:${NC}\n"
    for vs in $(get_lb_ssl_vservers); do
        if [ -n "$vs" ]; then
            cert=$(get_vserver_cert "$vs")
            printf "  - %s" "$vs"
            if [ -n "$cert" ]; then
                printf " (Cert: %s)" "$cert"
            fi
            printf "\n"
        fi
    done

    printf "\n${CYAN}Gateway/VPN Virtual Servers:${NC}\n"
    for vs in $(get_vpn_vservers); do
        if [ -n "$vs" ]; then
            cert=$(get_vserver_cert "$vs")
            printf "  - %s" "$vs"
            if [ -n "$cert" ]; then
                printf " (Cert: %s)" "$cert"
            fi
            printf "\n"
        fi
    done

    printf "\n${CYAN}Content Switching SSL Virtual Servers:${NC}\n"
    for vs in $(get_cs_ssl_vservers); do
        if [ -n "$vs" ]; then
            cert=$(get_vserver_cert "$vs")
            printf "  - %s" "$vs"
            if [ -n "$cert" ]; then
                printf " (Cert: %s)" "$cert"
            fi
            printf "\n"
        fi
    done

    printf "\nPress ENTER to continue..."
    read dummy
}

list_certificates_flow() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  INSTALLED SSL CERTIFICATES${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "\n"

    nscli_cmd "show ssl certkey" | grep -E "(Name:|Days to expiration)"

    printf "\nPress ENTER to continue..."
    read dummy
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    show_header

    # Check if running on NetScaler
    check_netscaler

    # Check/install acme.sh
    if ! check_acme; then
        log_warn "acme.sh not found"
        printf "Install acme.sh now? (y/n): "
        read install_confirm
        if [ "$install_confirm" = "y" ] || [ "$install_confirm" = "Y" ]; then
            install_acme || exit 1
        else
            log_error "acme.sh is required"
            exit 1
        fi
    fi

    log_success "acme.sh found at: $ACME_HOME"

    # Get NetScaler credentials
    setup_credentials

    # Main menu loop
    while true; do
        show_main_menu
        read choice

        case $choice in
            1) new_certificate_flow ;;
            2) install_certificate_flow ;;
            3) renew_certificate_flow ;;
            4) list_vservers_flow ;;
            5) list_certificates_flow ;;
            0)
                printf "\n"
                log_info "Goodbye!"
                exit 0
                ;;
            *)
                log_warn "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Run
main "$@"
