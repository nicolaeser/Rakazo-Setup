# Rakazo Setup

Self-hosts [Rakazo](https://github.com/elie222/rakazo) with Docker Compose behind Caddy on the host.

```sh
git clone https://github.com/nicolaeser/Rakazo-Setup.git rakazo && cd rakazo
./generate-env.sh
(cd /opt/rakazo && docker compose up -d)
./generate-env.sh --check
./generate-env.sh --owner
```

`generate-env.sh` deploys to `/opt/rakazo` (`--dir` for another place): it copies `docker-compose.yml` there, writes `.env`, writes `/etc/caddy/Caddyfile` (it asks before using sudo or replacing a configuration of yours), and lists the DNS records and remaining steps. Run it again after `git pull`; settings and secrets are kept. An install from before `/opt/rakazo` is moved there on the next run, after confirmation.

Optionally it sets up a Postfix mail server ([boky/postfix](https://github.com/bokysan/docker-postfix), Compose profile `mail`) under the Rakazo domain, with the certificate Caddy holds for it: it receives bot email (edge) and can send all of Rakazo's mail. `./generate-env.sh --help` lists all options.
