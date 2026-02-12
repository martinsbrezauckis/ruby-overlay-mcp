import base64
import hashlib
from datetime import datetime, timedelta, timezone

import pyotp
from cryptography.fernet import Fernet
from jose import jwt
from passlib.context import CryptContext

from .config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)


def create_access_token(subject: str, tenant_id: int, user_id: int) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.access_token_expire_minutes)
    payload = {"sub": subject, "tenant_id": tenant_id, "user_id": user_id, "exp": expire}
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def get_cipher() -> Fernet:
    if settings.encryption_key:
        key = settings.encryption_key.encode()
    else:
        key = base64.urlsafe_b64encode(hashlib.sha256(settings.jwt_secret_key.encode()).digest())
    return Fernet(key)


def encrypt_secret(value: str) -> str:
    return get_cipher().encrypt(value.encode()).decode()


def decrypt_secret(value: str) -> str:
    return get_cipher().decrypt(value.encode()).decode()


def key_hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def generate_totp_secret() -> str:
    return pyotp.random_base32()


def verify_totp(secret: str, otp: str) -> bool:
    return pyotp.TOTP(secret).verify(otp, valid_window=1)


def build_totp_uri(secret: str, email: str, tenant_slug: str) -> str:
    return pyotp.TOTP(secret).provisioning_uri(name=email, issuer_name=f"CRM-{tenant_slug}")
