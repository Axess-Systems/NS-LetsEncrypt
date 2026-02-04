# NetScaler Let's Encrypt Certificate Manager

A shell script for automating Let's Encrypt certificate management directly on Citrix NetScaler/ADC appliances. This tool handles certificate requests, installation, and binding to SSL virtual servers through an interactive menu-driven interface.

## Overview

This script runs directly on a NetScaler appliance and provides a streamlined workflow for:

- Requesting new Let's Encrypt certificates using DNS-01 challenge
- Installing certificates to the NetScaler SSL store
- Binding certificates to Load Balancer, Gateway/VPN, and Content Switching virtual servers
- Renewing existing certificates
- Listing current SSL configurations

## Features

- **Interactive Menu Interface** - Simple numbered menu system for all operations
- **Automatic acme.sh Installation** - Downloads and configures acme.sh if not present
- **DNS-01 Challenge Support** - Manual DNS validation for environments without HTTP challenge capability
- **Multi-Domain Certificates** - Support for Subject Alternative Names (SAN)
- **Smart Certificate Updates** - Detects existing certificates and offers update options
- **Bulk Binding** - Select multiple virtual servers for certificate binding in one operation
- **Configuration Persistence** - Automatically saves NetScaler configuration after changes

## Requirements

- Citrix NetScaler/ADC appliance (any supported version with shell access)
- Shell access to the NetScaler (SSH)
- NetScaler CLI credentials (nsroot or equivalent)
- Internet connectivity for Let's Encrypt validation
- DNS management access for creating TXT records

## Installation

1. Transfer the script to your NetScaler appliance:

```bash
scp ns-letsencrypt.sh nsroot@<netscaler-ip>:/var/nsconfig/
```

2. Connect to the NetScaler shell:

```bash
ssh nsroot@<netscaler-ip>
shell
```

3. Make the script executable:

```bash
chmod +x /var/nsconfig/ns-letsencrypt.sh
```

4. Run the script:

```bash
/var/nsconfig/ns-letsencrypt.sh
```

The script will automatically install acme.sh on first run if not already present.

## Usage

### Starting the Script

```bash
cd /var/nsconfig
./ns-letsencrypt.sh
```

You will be prompted for NetScaler CLI credentials. The default IP is 127.0.0.1 (localhost) since the script runs on the appliance.

### Main Menu Options

```
1) Request new certificate & bind
2) Install existing certificate & bind
3) Renew certificate
4) List SSL virtual servers
5) List installed certificates
0) Exit
```

### Requesting a New Certificate

1. Select option 1 from the main menu
2. Enter the primary domain name (e.g., `gateway.example.com`)
3. Optionally enter additional SAN domains (comma-separated)
4. Provide a certificate name for NetScaler (defaults to sanitised domain name)
5. Create the DNS TXT record(s) as displayed
6. Wait for DNS propagation and press Enter
7. Select virtual servers to bind the certificate

### DNS Challenge Process

When requesting a certificate, the script will display required DNS records:

```
DNS TXT RECORDS REQUIRED

Domain: _acme-challenge.gateway.example.com
TXT value: <validation-string>

Add the TXT record(s) to your DNS.
Wait for DNS propagation (1-5 minutes).
```

Create the TXT record in your DNS provider, verify propagation, then continue.

### Installing an Existing Certificate

Use option 2 to install certificates obtained through other means:

1. Provide the path to the certificate file (fullchain.pem or .cer)
2. Provide the path to the private key file
3. Enter a name for the certificate in NetScaler
4. Select virtual servers for binding

### Renewing Certificates

Option 3 lists all certificates managed by acme.sh and allows renewal:

1. View the list of managed certificates
2. Enter the domain to renew
3. Optionally specify the NetScaler certificate name to update

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ACME_HOME` | `/var/nsconfig/acme` | acme.sh installation directory |
| `CERT_KEY_BITS` | `2048` | RSA key size for certificates |

### File Locations

| Path | Purpose |
|------|---------|
| `/nsconfig/ssl/` | NetScaler SSL certificate storage |
| `/var/nsconfig/acme/` | Default acme.sh installation |
| `/root/.acme.sh/` | Alternative acme.sh location |

## How It Works

1. **Authentication** - The script uses `nscli` to communicate with the NetScaler NITRO API locally
2. **Certificate Request** - acme.sh handles the ACME protocol with Let's Encrypt using DNS-01 challenge
3. **Installation** - Certificate and key files are copied to `/nsconfig/ssl/` and registered with NetScaler
4. **Binding** - The script queries existing virtual servers and binds the certificate using CLI commands
5. **Persistence** - Configuration is saved with `save config` to survive reboots

## Virtual Server Types

The script supports binding to:

- **LB (Load Balancer)** - SSL and SSL_TCP protocol virtual servers
- **VPN/Gateway** - NetScaler Gateway virtual servers
- **CS (Content Switching)** - SSL content switching virtual servers

## Troubleshooting

### acme.sh Not Found

The script searches these locations:
- `/var/nsconfig/acme/acme.sh`
- `/root/.acme.sh/acme.sh`
- `/var/nsconfig/.acme.sh/acme.sh`

If not found, accept the prompt to install automatically.

### nscli Not Found

The script checks:
- `/netscaler/nscli`
- `/var/nsconfig/nscli`
- `/usr/local/bin/nscli`

Ensure you are running on a NetScaler appliance with shell access enabled.

### DNS Validation Failures

- Verify TXT record is correctly created with exact value
- Check DNS propagation using external tools (e.g., `dig TXT _acme-challenge.domain.com`)
- Wait sufficient time for propagation (typically 1-5 minutes)
- Ensure no conflicting TXT records exist

### Certificate Binding Errors

- Verify the virtual server is SSL-enabled
- Check that no incompatible certificate is already bound
- Ensure the certificate chain is complete (use fullchain, not just the certificate)

## Security Considerations

- The script prompts for credentials each run; they are not stored
- Private keys are set to mode 600 after installation
- Run the script from a secure shell session
- Consider restricting shell access after certificate deployment

## Limitations

- DNS-01 challenge only (no HTTP-01 support)
- Manual DNS record creation required
- Single appliance operation (no HA pair synchronisation)
- No automatic renewal scheduling (use cron or external automation)

## License

MIT License

Copyright (c) 2024

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Contributing

Contributions are welcome. Please submit issues and pull requests via GitHub.

## Acknowledgements

- [acme.sh](https://github.com/acmesh-official/acme.sh) - ACME protocol client
- [Let's Encrypt](https://letsencrypt.org/) - Free certificate authority
