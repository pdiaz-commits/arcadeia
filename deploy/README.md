# Deploying Arcade AI

Reference deployment for the AWS Lightsail box already running
`machinelearning.pablodiaz.eu` (Columns AI), Ubuntu 24.04 + nginx +
systemd + certbot. This mirrors that exact pattern for the
`machinelearning-arcade.pablodiaz.eu` subdomain.

## 1. Get the code onto the server

```bash
# on the server, as ubuntu:
cd /var/www
git clone https://github.com/<your-org>/arcadeia.git arcadeia
cd arcadeia
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 2. Configure the admin token (optional but recommended)

Edit `/etc/systemd/system/arcadeia-web.service` and set
`ARCADEIA_ADMIN_TOKEN` to a real secret (uploads are disabled otherwise).

## 3. systemd service

```bash
sudo cp deploy/systemd/arcadeia-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arcadeia-web.service
sudo systemctl status arcadeia-web.service
curl -s http://127.0.0.1:8014/healthz
```

## 4. nginx reverse proxy

```bash
sudo cp deploy/nginx/machinelearning-arcade.pablodiaz.eu /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/machinelearning-arcade.pablodiaz.eu /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

At this point the app is live over plain HTTP at
`http://machinelearning-arcade.pablodiaz.eu/` **once DNS for that subdomain
points at this server's IP** (A record — ask whoever controls DNS for
`pablodiaz.eu` to add it; this cannot be done from the server itself).

## 5. TLS (after DNS is live)

```bash
sudo certbot --nginx -d machinelearning-arcade.pablodiaz.eu
```

This rewrites the nginx config in place (adds the 443 server block + the
80→443 redirect), exactly like it already did for
`/etc/nginx/sites-available/machinelearning.pablodiaz.eu`. Certbot will also
set up the renewal timer automatically (shared with the other certs on this
box).

## Updating after a new push

```bash
cd /var/www/arcadeia
git pull
source .venv/bin/activate
pip install -r requirements.txt
sudo systemctl restart arcadeia-web.service
```
