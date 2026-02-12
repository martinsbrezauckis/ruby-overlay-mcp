from fastapi import FastAPI
from sqlalchemy.orm import Session

from .config import settings
from .db import Base, engine
from .models import Tenant, Translation, User
from .routers import admin, auth, crm, inventory, invoices
from .security import get_password_hash

app = FastAPI(title=settings.app_name)


@app.on_event("startup")
def startup():
    Base.metadata.create_all(bind=engine)
    db = Session(bind=engine)

    tenant = db.query(Tenant).filter(Tenant.slug == settings.default_tenant_slug).first()
    if not tenant:
        tenant = Tenant(slug=settings.default_tenant_slug, name=settings.default_tenant_name)
        db.add(tenant)
        db.commit()
        db.refresh(tenant)

    admin_user = (
        db.query(User)
        .filter(User.email == settings.default_admin_email, User.tenant_id == tenant.id)
        .first()
    )
    if not admin_user:
        db.add(
            User(
                tenant_id=tenant.id,
                email=settings.default_admin_email,
                full_name="System Admin",
                hashed_password=get_password_hash(settings.default_admin_password),
                is_admin=True,
                modules="crm,inventory,invoices,admin",
            )
        )

    existing = {
        (t.language_code, t.key)
        for t in db.query(Translation).filter(Translation.tenant_id == tenant.id).all()
    }
    seed = [
        ("lv", "login.title", "Pieslēgties"),
        ("en", "login.title", "Log in"),
    ]
    for lang, key, value in seed:
        if (lang, key) not in existing:
            db.add(Translation(tenant_id=tenant.id, language_code=lang, key=key, value=value))

    db.commit()
    db.close()


@app.get("/health")
def health():
    return {"status": "ok", "version": "0.1"}


app.include_router(auth.router)
app.include_router(admin.router)
app.include_router(crm.router)
app.include_router(inventory.router)
app.include_router(invoices.router)
