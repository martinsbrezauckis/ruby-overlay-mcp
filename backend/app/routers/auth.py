from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session

from ..db import get_db
from ..deps import get_current_user
from ..models import Tenant, User
from ..schemas import LoginRequest, Token, TwoFactorSetupResponse, TwoFactorVerifyRequest
from ..security import (
    build_totp_uri,
    create_access_token,
    decrypt_secret,
    encrypt_secret,
    generate_totp_secret,
    verify_password,
    verify_totp,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def _issue_token_for_user(user: User) -> Token:
    return Token(access_token=create_access_token(user.email, tenant_id=user.tenant_id, user_id=user.id))


@router.post("/token", response_model=Token)
def login_legacy(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == form_data.username).first()
    if not user or not verify_password(form_data.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Incorrect email or password")
    if user.two_factor_enabled:
        raise HTTPException(status_code=400, detail="2FA enabled. Use /auth/login with otp_code")
    return _issue_token_for_user(user)


@router.post("/login", response_model=Token)
def login(payload: LoginRequest, db: Session = Depends(get_db)):
    tenant = db.query(Tenant).filter(Tenant.slug == payload.tenant_slug).first()
    if not tenant:
        raise HTTPException(status_code=401, detail="Invalid tenant or credentials")

    user = (
        db.query(User)
        .filter(User.email == payload.email, User.tenant_id == tenant.id, User.is_active.is_(True))
        .first()
    )
    if not user or not verify_password(payload.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Invalid tenant or credentials")

    if user.two_factor_enabled:
        if not payload.otp_code:
            raise HTTPException(status_code=401, detail="OTP code required")
        secret = decrypt_secret(user.two_factor_secret_encrypted)
        if not verify_totp(secret, payload.otp_code):
            raise HTTPException(status_code=401, detail="Invalid OTP code")

    return _issue_token_for_user(user)


@router.post("/2fa/setup", response_model=TwoFactorSetupResponse)
def setup_2fa(current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    if current_user.two_factor_enabled:
        raise HTTPException(status_code=400, detail="2FA already enabled")

    tenant = db.query(Tenant).filter(Tenant.id == current_user.tenant_id).first()
    secret = generate_totp_secret()
    current_user.two_factor_secret_encrypted = encrypt_secret(secret)
    db.commit()
    return TwoFactorSetupResponse(provisioning_uri=build_totp_uri(secret, current_user.email, tenant.slug))


@router.post("/2fa/verify")
def verify_2fa(payload: TwoFactorVerifyRequest, current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    if not current_user.two_factor_secret_encrypted:
        raise HTTPException(status_code=400, detail="2FA setup is required first")

    secret = decrypt_secret(current_user.two_factor_secret_encrypted)
    if not verify_totp(secret, payload.otp_code):
        raise HTTPException(status_code=400, detail="Invalid OTP code")

    current_user.two_factor_enabled = True
    db.commit()
    return {"status": "2fa_enabled"}
