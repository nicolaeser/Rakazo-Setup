# Rakazo Setup

Self-hosts [Rakazo](https://github.com/elie222/rakazo) with Docker Compose behind Caddy on the host.

```sh
wget -q https://raw.githubusercontent.com/nicolaeser/Rakazo-Setup/main/generate-env.sh
bash generate-env.sh
/opt/rakazo/generate-env.sh --check
/opt/rakazo/generate-env.sh --owner
```

`generate-env.sh` downloads `docker-compose.yml`, the Caddyfile template and the Postfix hooks with wget from this repository and installs them and itself in `/opt/rakazo` (`--dir` for another place). It writes `.env`, writes `/etc/caddy/Caddyfile` (it asks before using sudo or replacing a configuration of yours), lists the DNS records and remaining steps, and then pulls the images and starts the stack. Run `/opt/rakazo/generate-env.sh` again to update or change settings: it fetches the current version first, and settings and secrets are kept. An install from before `/opt/rakazo` is moved there after confirmation.

Optionally it sets up a Postfix mail server ([boky/postfix](https://github.com/bokysan/docker-postfix), Compose profile `mail`) under the Rakazo domain, with the certificate Caddy holds for it: it receives bot email (edge) and can send all of Rakazo's mail. `bash generate-env.sh --help` lists all options.
