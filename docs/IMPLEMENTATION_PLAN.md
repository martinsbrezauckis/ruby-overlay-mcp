# CRM implementation plan (v0.1 baseline + growth path)

## Confirmed decisions (from product clarification)
1. Architecture: **multi-tenant** from the start.
2. Authentication: **2FA required capability** (TOTP in v0.1).
3. Invoice process: no approval workflow in current modules (manual/add/import/save only).
4. API key policy: **write-only**.
5. Backup target: nightly backup (acceptable max data loss: one working day).
6. GDPR policy: not applied in current development phase (internal company usage).

## Delivered in repository (v0.1)
1. Multi-tenant data model and tenant-scoped API reads/writes.
2. JWT auth with tenant/user claims and account activity checks.
3. TOTP 2FA endpoints for setup and verification.
4. Admin endpoints for users, module toggles, translations, and encrypted write-only API key storage.
5. CRM, inventory, and invoice endpoints with import/export support for `json/xml/csv/pdf`.
6. Ubuntu deployment via Docker.

## Next milestones
1. **Latvian e-invoice strict compliance (v0.2)**
   - Implement schema/profile parser + validator using official examples:
     https://latvija.gov.lv/Content/Erekini
2. **Frontend UI (gray/blue modern style)**
   - Polished dashboard UX, module navigation, tenant-aware sign-in, 2FA onboarding.
3. **Security hardening**
   - Rate limiting, account lockout, audit logs, key rotation tooling, and backup restore checks.
4. **Public availability readiness**
   - Tenant provisioning flow, onboarding, observability, and scalable PostgreSQL deployment profile.

## Open questions for next step
1. Should tenant onboarding be self-service, admin-created, or invite-only?
2. Preferred primary database for public phase: PostgreSQL only, or PostgreSQL + read replicas?
3. Should we enforce 2FA for all users immediately or allow policy per tenant/user role?
