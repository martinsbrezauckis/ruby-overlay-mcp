# CRM Starter v0.1 (FastAPI)

Secure, Ubuntu-deployable **multi-tenant** CRM foundation with:
- Admin APIs (user management, module toggles, translation entries)
- Write-only API key vault (encrypted at rest)
- Authentication with JWT + TOTP 2FA
- CRM entities (clients, companies)
- Inventory management
- Invoice management (incoming/outgoing, manual create/import)
- Import/export endpoints supporting JSON/XML/CSV/PDF
- Docker deployment for Ubuntu

## Quick start (local)

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

## Quick start (Docker)

```bash
docker compose up --build
```

API docs: `http://localhost:8000/docs`

## Security highlights
- Passwords hashed with bcrypt
- JWT authentication with tenant isolation claims (`tenant_id`, `user_id`)
- TOTP 2FA support (`/auth/2fa/setup`, `/auth/2fa/verify`)
- API secrets encrypted at rest using Fernet (`ENCRYPTION_KEY`)
- Write-only API key policy (no plaintext retrieval endpoints)
- Module-based access checks per user
- Input validation with Pydantic

## Tenant-aware login flow
1. `POST /auth/login` with `tenant_slug`, `email`, `password` (+ `otp_code` if 2FA enabled)
2. Use returned bearer token for protected APIs.

Legacy `POST /auth/token` remains for compatibility but does not support 2FA-enabled accounts.

## Latvian e-invoice
v0.1 supports import/export file formats (`json/xml/csv/pdf`) and manual invoice save flow.
A strict Latvian e-invoice compliance parser/validator should be implemented in v0.2 using the official spec/examples.

## Backup and operations baseline
- Target backup policy: nightly backups (max 1 working day data loss / RPO ~24h).
- Recommended next step: scheduled DB snapshot + restore drill automation.

## Default bootstrap tenant/admin
Set via environment variables:
- `DEFAULT_TENANT_SLUG`
- `DEFAULT_TENANT_NAME`
- `DEFAULT_ADMIN_EMAIL`
- `DEFAULT_ADMIN_PASSWORD`

> Never commit real secrets. Use `.env` in deployment.
