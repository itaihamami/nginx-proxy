# Automated Nginx Reverse Proxy with Free SSL (Let's Encrypt)

A lightweight reverse proxy setup based on `nginxproxy/nginx-proxy` and `nginxproxy/acme-companion`. Automatically handles domain routing, SSL certificate generation, and automated renewals for proxied Docker containers.

---

## 📋 Prerequisites

1. **Docker & Docker Compose** installed on your server.
2. A shared external Docker network named `proxy_network`. Create it once on your host before starting the proxy:

```bash
docker network create proxy_network
```

---

## 🚀 Quick Start (Proxy Setup)

1. Clone this repository to your server.
2. Create a `.env` file with your email address:
   ```env
   DEFAULT_EMAIL=your-email@example.com
   ```
3. Make sure your custom Nginx configurations are set in `etc/additional_config.conf` (e.g., upload file size limits, timeouts, header buffer sizes).
4. Start the reverse proxy:

```bash
docker compose up -d
```

---

## Optional: Cloudflare visitor IPs

For Cloudflare-proxied domains, enable visitor IP restoration by adding this to
`.env` (Linux):

```env
COMPOSE_FILE=docker-compose.yml:docker-compose.cloudflare.yml
```

Then apply it, recreating the proxy briefly:

```bash
mkdir -p var/cloudflare
docker compose up -d
docker compose exec nginx-proxy nginx -t
```

Compose reads this setting on subsequent commands, including updates and restarts.
Without it, the base setup has no Cloudflare dependency. Remove the setting and
run `docker compose up -d` to disable the integration.

The startup script `etc/cloudflare-entrypoint.sh` fetches Cloudflare's IPv4/IPv6
lists over verified HTTPS, validates them with Nginx, and atomically saves
`var/cloudflare/trusted-proxies.conf`
with a UTC timestamp. Only trusted Cloudflare connections can supply the visitor
IP via `CF-Connecting-IP`; DNS-only domains keep their direct connection address.
The generated list is excluded from Git. No extra packages are needed.

Refreshes run on container starts/restarts, not Nginx reloads or a schedule. If a
fetch fails, a validated cache up to seven days old is used; otherwise startup
stops. First startup requires outbound HTTPS access. This restores client IPs;
it does not restrict origin access to Cloudflare. See [Cloudflare's guidance](https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/restoring-original-visitor-ips/).

---

## 🔗 Connecting Application Services

To route web traffic and issue SSL certificates to an application container (Node.js, WordPress, PHP, Python, etc.), meet two requirements in the application's `docker-compose.yml`:

1. Attach the web container to the `proxy_network` network.
2. Add the `VIRTUAL_HOST` and `LETSENCRYPT_HOST` environment variables.

### Environment Variables

| Variable | Description | Example |
| :--- | :--- | :--- |
| `VIRTUAL_HOST` | Domain(s) Nginx will route to this container | `example.com, www.example.com` |
| `LETSENCRYPT_HOST` | Domain(s) Let's Encrypt will issue SSL certs for | `example.com, www.example.com` |
| `VIRTUAL_PORT` *(Optional)* | Container internal port if different than `80` | `3000` |

---

## 💡 Example Application Configuration

Below is a modern `docker-compose.yml` example for an application (e.g., Node.js or WordPress container) connecting through the reverse proxy:

```yaml
services:
  web-app:
    image: nginx:1.27-alpine
    container_name: my-website
    restart: unless-stopped
    volumes:
      - ./public:/usr/share/nginx/html:ro
    environment:
      - VIRTUAL_HOST=app.example.com
      - LETSENCRYPT_HOST=app.example.com
    networks:
      - default
      - proxy_network

networks:
  # Internal network for the app's internal services (DB, cache, etc.)
  default:
    driver: bridge
  # External network connecting the app to the Nginx reverse proxy
  proxy_network:
    external: true
```

---

## ⚙️ Custom Global Nginx Directives

Global Nginx overrides (like increased upload sizes, timeouts, and buffer sizes) are maintained in `etc/additional_config.conf` and mounted directly into the proxy container:

* **Upload Limit:** `client_max_body_size 64m;`
* **Timeouts:** `proxy_read_timeout 300;` (5 minutes)
* **Security:** `server_tokens off;` (Hides Nginx version info)
* **Header Buffers:** Prevents `502 Bad Gateway` errors from large cookies or JWT headers.
