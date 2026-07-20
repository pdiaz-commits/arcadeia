# Deploying Arcade AI (`arcade.arcaderooms.uk`)

AWS Lightsail (Ubuntu 24.04) + nginx + systemd + certbot.

**Domain layout on arcaderooms.uk:**

| Host | App |
|------|-----|
| `arcaderooms.uk` (+ `www`) | MAME Explorer — `mame_explorer/deploy/nginx/arcaderooms.uk` |
| `arcade.arcaderooms.uk` | Arcade AI (this repo) |

**DNS:** A record `arcade.arcaderooms.uk` → this server's public IP.

## 1. Code on the server

```bash
# as ubuntu on Lightsail:
cd /var/www
sudo mkdir -p /var/www && sudo chown ubuntu:ubuntu /var/www
git clone https://github.com/pdiaz-commits/arcadeia.git arcadeia
# or: cd /var/www/arcadeia && git pull
cd /var/www/arcadeia
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 2. systemd

```bash
sudo cp deploy/systemd/arcadeia-web.service /etc/systemd/system/
# set ARCADEIA_ADMIN_TOKEN to a real secret
sudo nano /etc/systemd/system/arcadeia-web.service
sudo systemctl daemon-reload
sudo systemctl enable --now arcadeia-web.service
curl -s http://127.0.0.1:8014/healthz
```

## 3. nginx

```bash
sudo cp deploy/nginx/arcade.arcaderooms.uk /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/arcade.arcaderooms.uk /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

HTTP should answer at `http://arcade.arcaderooms.uk/` once DNS points here.

## 4. TLS

```bash
sudo certbot --nginx -d arcade.arcaderooms.uk
```

## Updating after a push

```bash
cd /var/www/arcadeia
git pull
source .venv/bin/activate
pip install -r requirements.txt
sudo systemctl restart arcadeia-web.service
```

## Legacy

- `deploy/nginx/arcaderooms.uk` — deprecated stub; root domain is Moodle Explorer.
- `deploy/nginx/machinelearning-arcade.pablodiaz.eu` — old subdomain reference.
