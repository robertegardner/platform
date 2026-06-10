#!/usr/bin/env bash
# Rendered by Terraform, executed via SSH as root inside the distribution LXC.
# Installs Icecast and lays down the platform-managed config. RE-RUN SAFE:
# icecast.xml is written only when it does not carry the platform-managed marker,
# so manual/UI edits made after first provision are never clobbered.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing icecast2"
# Mute the package's interactive setup prompt; config comes from this script.
echo "icecast2 icecast2/icecast-setup boolean false" | debconf-set-selections
apt-get update -qq
apt-get install -y -qq icecast2 curl

echo "==> icecast.xml (write only if not platform-managed)"
if grep -q "platform-managed" /etc/icecast2/icecast.xml 2>/dev/null; then
  echo "    /etc/icecast2/icecast.xml already platform-managed - keeping it"
else
  cat > /etc/icecast2/icecast.xml <<'EOF'
<!-- platform-managed: written by the distribution provisioner. Edits survive
     re-provisioning (the provisioner only writes when this marker is absent). -->
<icecast>
    <location>rack</location>
    <admin>icemaster@${icecast_hostname}</admin>

    <limits>
        <clients>100</clients>
        <sources>10</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>262144</burst-size>
    </limits>

    <authentication>
        <source-password>${source_password}</source-password>
        <relay-password>${source_password}</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>${admin_password}</admin-password>
    </authentication>

    <hostname>${icecast_hostname}</hostname>

    <listen-socket>
        <port>8000</port>
    </listen-socket>

    <http-headers>
        <header name="Access-Control-Allow-Origin" value="*" />
    </http-headers>

    <fileserve>1</fileserve>

    <paths>
        <basedir>/usr/share/icecast2</basedir>
        <logdir>/var/log/icecast2</logdir>
        <webroot>/usr/share/icecast2/web</webroot>
        <adminroot>/usr/share/icecast2/admin</adminroot>
        <alias source="/" destination="/status.xsl"/>
    </paths>

    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
        <logsize>10000</logsize>
        <logarchive>1</logarchive>
    </logging>

    <security>
        <chroot>0</chroot>
        <changeowner>
            <user>icecast2</user>
            <group>icecast</group>
        </changeowner>
    </security>
</icecast>
EOF
  chown root:icecast /etc/icecast2/icecast.xml
  chmod 640 /etc/icecast2/icecast.xml
  echo "    wrote /etc/icecast2/icecast.xml"
fi

# Debian/Ubuntu historically gate the daemon behind /etc/default/icecast2.
if [ -f /etc/default/icecast2 ]; then
  sed -i 's/^ENABLE=.*/ENABLE=true/' /etc/default/icecast2
fi

echo "==> enable + restart icecast2 (restart, never enable --now: loads new config)"
systemctl enable icecast2
systemctl restart icecast2
sleep 2
systemctl is-active icecast2

echo "==> provisioning complete"
curl -sS -m 5 http://localhost:8000/status-json.xsl >/dev/null && echo "    status endpoint OK"
