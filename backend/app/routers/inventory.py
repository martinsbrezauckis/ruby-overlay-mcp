from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..db import get_db
from ..deps import require_module
from ..models import InventoryItem, User
from ..schemas import InventoryItemCreate

router = APIRouter(prefix="/inventory", tags=["inventory"])


@router.post("/items")
def create_item(
    payload: InventoryItemCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_module("inventory")),
):
    item = InventoryItem(tenant_id=current_user.tenant_id, **payload.model_dump())
    db.add(item)
    db.commit()
    db.refresh(item)
    return item


@router.get("/items")
def list_items(db: Session = Depends(get_db), current_user: User = Depends(require_module("inventory"))):
    return db.query(InventoryItem).filter(InventoryItem.tenant_id == current_user.tenant_id).all()
