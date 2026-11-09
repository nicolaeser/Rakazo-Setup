# Rakazo Setup

Self-hosts [Rakazo](https://github.com/elie222/rakazo) with Docker Compose behind Caddy on the host.

```sh
git clone https://github.com/nicolaeser/Rakazo-Setup.git rakazo && cd rakazo
./generate-env.sh
docker compose up -d
./generate-env.sh --check
./generate-env.sh --owner
```

`generate-env.sh` writes `.env` and prints the remaining steps (DNS, Caddy, Docker). `./generate-env.sh --help` lists all options.
