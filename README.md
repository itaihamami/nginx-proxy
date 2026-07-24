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
3. Make sure your custom Nginx configurations are set in `additional_config.conf` (e.g., upload file size limits, timeouts, header buffer sizes).
4. Start the reverse proxy:

```bash
docker compose up -d
```

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

Global Nginx overrides (like increased upload sizes, timeouts, and buffer sizes) are maintained in `additional_config.conf` and mounted directly into the proxy container:

* **Upload Limit:** `client_max_body_size 64m;`
* **Timeouts:** `proxy_read_timeout 300;` (5 minutes)
* **Security:** `server_tokens off;` (Hides Nginx version info)
* **Header Buffers:** Prevents `502 Bad Gateway` errors from large cookies or JWT headers.
