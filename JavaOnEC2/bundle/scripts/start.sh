#!/bin/bash
set -euo pipefail
sudo chown -R app:app /opt/app
# ensure default version file exists
if [ ! -f /opt/app/app.env ]; then echo "APP_VERSION=v1" | sudo tee /opt/app/app.env >/dev/null; fi
sudo bash -c 'cat >/etc/systemd/system/app.service <<EOF
[Unit]
Description=Spring Boot App
After=network.target

[Service]
User=app
WorkingDirectory=/opt/app
EnvironmentFile=/opt/app/app.env
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=/usr/bin/java -Dserver.port=80 -jar /opt/app/app.jar
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'

sudo systemctl daemon-reload
sudo systemctl enable app
sudo systemctl restart app

# Readiness loop (~180s)
for i in $(seq 1 90); do
  if wget -qO- http://localhost/health >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
journalctl -u app -n 60 --no-pager || true
exit 1