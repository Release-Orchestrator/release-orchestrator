# Release Orchestrator

Unified deployment stack for the Release Orchestrator platform. This repository
contains the single `docker-compose.yml` that boots the entire sample-app
foundation: a React frontend, an API gateway, and four independent
microservices, each with its own PostgreSQL database.

## Stack

| Service         | Port   | Notes                                        |
|-----------------|--------|----------------------------------------------|
| frontend        | :5173  | React + Vite, nginx, proxies `/api/`         |
| api-gateway     | :8080  | Routes + JWT validation against auth-service |
| user-service    | (int)  | User CRUD, database-per-service              |
| order-service   | (int)  | Depends on user-service / payment-service    |
| payment-service | (int)  | Payment lifecycle                           |
| auth-service    | (int)  | JWT login/register, bcrypt credentials       |
| user-db         | :5432  | PostgreSQL 16                                |
| order-db        | :5434  | PostgreSQL 16                                |
| payment-db      | :5433  | PostgreSQL 16                                |
| auth-db         | :5435  | PostgreSQL 16                                |

Service containers are not published to the host; they communicate over the
compose network. Databases are published for debugging.

## Prerequisites

- Docker Engine with the Compose v2 plugin
- `git`

## Deploy

Clone this repository together with the service repositories so the compose
build contexts resolve:

```bash
git clone https://github.com/Release-Orchestrator/release-orchestrator.git ~/release-platform
cd ~/release-platform

git clone https://github.com/Release-Orchestrator/user-service.git
git clone https://github.com/Release-Orchestrator/order-service.git
git clone https://github.com/Release-Orchestrator/payment-service.git
git clone https://github.com/Release-Orchestrator/auth-service.git
git clone https://github.com/Release-Orchestrator/api-gateway.git
git clone https://github.com/Release-Orchestrator/frontend.git

docker compose up --build
```

### JWT secret

Auth-service refuses to start without `JWT_SECRET`. A development default is
baked into the compose file; override it for any non-local environment:

```bash
cp .env.example .env        # then edit JWT_SECRET
docker compose up --build
```

## Endpoints

- Frontend UI: http://localhost:5173
- API gateway: http://localhost:8080
- Health check: http://localhost:8080/health

## Repositories

- [frontend](https://github.com/Release-Orchestrator/frontend)
- [api-gateway](https://github.com/Release-Orchestrator/api-gateway)
- [user-service](https://github.com/Release-Orchestrator/user-service)
- [order-service](https://github.com/Release-Orchestrator/order-service)
- [payment-service](https://github.com/Release-Orchestrator/payment-service)
- [auth-service](https://github.com/Release-Orchestrator/auth-service)
