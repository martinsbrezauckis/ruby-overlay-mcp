from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..db import get_db
from ..deps import require_admin
from ..models import ApiCredential, Translation, User
from ..schemas import ApiCredentialCreate, TranslationCreate, UserCreate, UserOut
from ..security import encrypt_secret, get_password_hash, key_hash

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


@router.post("/users", response_model=UserOut)
def create_user(payload: UserCreate, db: Session = Depends(get_db), admin_user: User = Depends(require_admin)):
    user = User(
        tenant_id=admin_user.tenant_id,
        email=payload.email,
        full_name=payload.full_name,
        hashed_password=get_password_hash(payload.password),
        is_admin=payload.is_admin,
        modules=",".join(payload.modules),
    )
    db.add(user)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="User with this email already exists in tenant")
    db.refresh(user)
    return UserOut(
        id=user.id,
        email=user.email,
        full_name=user.full_name,
        is_admin=user.is_admin,
        modules=user.modules.split(",") if user.modules else [],
        two_factor_enabled=user.two_factor_enabled,
    )


@router.post("/translations")
def create_translation(payload: TranslationCreate, db: Session = Depends(get_db), admin_user: User = Depends(require_admin)):
    item = Translation(tenant_id=admin_user.tenant_id, language_code=payload.language_code, key=payload.key, value=payload.value)
    db.add(item)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Translation key already exists for this language")
    return {"status": "ok", "id": item.id}


@router.post("/api-keys")
def store_api_key(payload: ApiCredentialCreate, db: Session = Depends(get_db), admin_user: User = Depends(require_admin)):
    encrypted = encrypt_secret(payload.value)
    row = ApiCredential(
        tenant_id=admin_user.tenant_id,
        name=payload.name,
        encrypted_value=encrypted,
        key_hash=key_hash(payload.value),
    )
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="API key name already exists")
    return {"status": "stored", "name": payload.name, "policy": "write_only"}
