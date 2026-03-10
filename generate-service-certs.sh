#!/bin/bash
# Generate SSL certificates for HarborMind services
# Creates CA + certs for orchestrator, lighthouse, and scanner

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="$BASE_DIR/certs-new"
CA_DAYS=3650
CERT_DAYS=365

rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

echo "=== Generating HarborMind SSL Certificates ==="
echo "Output directory: $CERT_DIR"
echo ""

# 1. Generate CA
echo "1. Generating Certificate Authority..."
openssl genrsa -out harbormind-ca.key 4096
openssl req -x509 -new -nodes -key harbormind-ca.key -sha256 -days $CA_DAYS \
    -out harbormind-ca.crt \
    -subj "/C=US/ST=California/L=San Francisco/O=HarborMind/OU=Security/CN=HarborMind CA"
echo "   Created: harbormind-ca.key, harbormind-ca.crt"

# 2. Generate Orchestrator certificate
echo ""
echo "2. Generating Orchestrator certificate (CN=orchestrator.harbormind.local)..."
cat > orchestrator.cnf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = US
ST = California
L = San Francisco
O = HarborMind
OU = Orchestrator
CN = orchestrator.harbormind.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = orchestrator.harbormind.local
DNS.2 = orchestrator.harbormind.internal
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

openssl genrsa -out orchestrator.key 2048
openssl req -new -key orchestrator.key -out orchestrator.csr -config orchestrator.cnf
openssl x509 -req -in orchestrator.csr -CA harbormind-ca.crt -CAkey harbormind-ca.key \
    -CAcreateserial -out orchestrator.crt -days $CERT_DAYS -sha256 \
    -extfile orchestrator.cnf -extensions req_ext
cat orchestrator.crt harbormind-ca.crt > orchestrator-chain.crt
echo "   Created: orchestrator.key, orchestrator.crt, orchestrator-chain.crt"

# 3. Generate Lighthouse certificate
echo ""
echo "3. Generating Lighthouse certificate (CN=lighthouse.harbormind.local)..."
cat > lighthouse.cnf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = US
ST = California
L = San Francisco
O = HarborMind
OU = Lighthouse
CN = lighthouse.harbormind.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = lighthouse.harbormind.local
DNS.2 = lighthouse.harbormind.internal
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

openssl genrsa -out lighthouse.key 2048
openssl req -new -key lighthouse.key -out lighthouse.csr -config lighthouse.cnf
openssl x509 -req -in lighthouse.csr -CA harbormind-ca.crt -CAkey harbormind-ca.key \
    -CAcreateserial -out lighthouse.crt -days $CERT_DAYS -sha256 \
    -extfile lighthouse.cnf -extensions req_ext
cat lighthouse.crt harbormind-ca.crt > lighthouse-chain.crt
echo "   Created: lighthouse.key, lighthouse.crt, lighthouse-chain.crt"

# 4. Generate Scanner certificate
echo ""
echo "4. Generating Scanner certificate (CN=scanner.harbormind.local)..."
cat > scanner.cnf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = US
ST = California
L = San Francisco
O = HarborMind
OU = Scanner
CN = scanner.harbormind.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = scanner.harbormind.local
DNS.2 = scanner.harbormind.internal
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

openssl genrsa -out scanner.key 2048
openssl req -new -key scanner.key -out scanner.csr -config scanner.cnf
openssl x509 -req -in scanner.csr -CA harbormind-ca.crt -CAkey harbormind-ca.key \
    -CAcreateserial -out scanner.crt -days $CERT_DAYS -sha256 \
    -extfile scanner.cnf -extensions req_ext
cat scanner.crt harbormind-ca.crt > scanner-chain.crt
echo "   Created: scanner.key, scanner.crt, scanner-chain.crt"

# 5. Create ca-bundle for clients
echo ""
echo "5. Creating CA bundle..."
cp harbormind-ca.crt ca-bundle.crt
echo "   Created: ca-bundle.crt"

# Cleanup temp files
rm -f *.csr *.cnf *.srl

# Summary
echo ""
echo "=== Certificate Generation Complete ==="
echo ""
echo "Files created:"
ls -la "$CERT_DIR"
echo ""
echo "=== CA Private Key (store in Secrets Manager) ==="
echo ""
cat harbormind-ca.key
echo ""
echo "=== Next Steps ==="
echo "1. Copy harbormind-ca.key to Secrets Manager"
echo "2. Run: ./scripts/deploy-certs.sh"
