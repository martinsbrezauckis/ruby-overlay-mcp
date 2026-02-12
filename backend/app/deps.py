from collections.abc import Callable

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from sqlalchemy.orm import Session

from .config import settings
from .db import get_db
from .models import User

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")


def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
    )
    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
        email: str | None = payload.get("sub")
        tenant_id: int | None = payload.get("tenant_id")
        user_id: int | None = payload.get("user_id")
        if email is None or tenant_id is None or user_id is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception

    user = (
        db.query(User)
        .filter(User.id == user_id, User.email == email, User.tenant_id == tenant_id)
        .first()
    )
    if user is None or not user.is_active:
        raise credentials_exception
    return user


def require_admin(current_user: User = Depends(get_current_user)) -> User:
    if not current_user.is_admin:
        raise HTTPException(status_code=403, detail="Admin access required")
    return current_user


def require_module(module_name: str) -> Callable[[User], User]:
    def checker(current_user: User = Depends(get_current_user)) -> User:
        modules = {m.strip() for m in current_user.modules.split(",") if m.strip()}
        if module_name not in modules and not current_user.is_admin:
            raise HTTPException(status_code=403, detail=f"Module '{module_name}' is disabled for user")
        return current_user

    return checker
