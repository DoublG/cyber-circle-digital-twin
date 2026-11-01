#!/bin/sh
# The installation's own CA and the gamemaster PC's server certificate (the
# control server's https, the broker's mqtts and wss). Devices trust ca.pem
# once (browser / phone / --ca) instead of accepting a warning per server.
#   deploy/certs/make_certs.sh            (the gamemaster compose runs it at start)
#   CERT_NAMES="DNS:gamemaster-pc.lan,IP:192.168.1.10" deploy/certs/make_certs.sh
# The CA is made once (keep ca.key safe); the server certificate again when the
# names change. Names always in it: broker, control (the compose services),
# localhost, 127.0.0.1.
set -e
cd "${CERT_DIR:-$(dirname "$0")}"
SAN="DNS:broker,DNS:control,DNS:localhost,IP:127.0.0.1${CERT_NAMES:+,$CERT_NAMES}"
if [ ! -f ca.pem ]; then
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -keyout ca.key -out ca.pem \
        -subj "/CN=Cyber Circle CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
    echo "made the CA: ca.pem"
fi
if [ ! -f server.pem ] || [ "$(cat server.san 2>/dev/null)" != "$SAN" ]; then
    openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=Cyber Circle gamemaster PC"
    printf "subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" \
        "$SAN" > server.ext
    # 825 days: the most iPhones accept
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 -out server.pem -extfile server.ext
    rm -f server.csr server.ext
    echo "$SAN" > server.san
    echo "made server.pem for $SAN"
fi
chmod 644 server.pem ca.pem server.key   # (the broker runs as its own user: a test setup)
