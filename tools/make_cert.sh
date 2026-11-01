#!/usr/bin/env bash
# A self-signed certificate for the control server's https (the gamemaster web
# app on an iPhone may only use the camera on an https page):
#   tools/make_cert.sh 192.168.1.10            -> control/cert.pem, control/key.pem
#   control/.venv/bin/python control/server.py ... --ssl-cert control/cert.pem --ssl-key control/key.pem
# On each iPhone open https://192.168.1.10:8080/gm/ once and accept the warning.
set -e
IP=${1:?usage: tools/make_cert.sh <the server IP address>}
cd "$(dirname "$0")/../control"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem \
    -subj "/CN=Cyber Circle $IP" -addext "subjectAltName=IP:$IP,DNS:localhost"
echo "control/cert.pem and control/key.pem for $IP"
