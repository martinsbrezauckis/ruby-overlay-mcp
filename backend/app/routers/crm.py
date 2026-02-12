from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..db import get_db
from ..deps import require_module
from ..models import Client, Company, User
from ..schemas import ClientCreate, CompanyCreate

router = APIRouter(prefix="/crm", tags=["crm"])


@router.post("/companies")
def create_company(
    payload: CompanyCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_module("crm")),
):
    company = Company(tenant_id=current_user.tenant_id, **payload.model_dump())
    db.add(company)
    db.commit()
    db.refresh(company)
    return company


@router.get("/companies")
def list_companies(db: Session = Depends(get_db), current_user: User = Depends(require_module("crm"))):
    return db.query(Company).filter(Company.tenant_id == current_user.tenant_id).all()


@router.post("/clients")
def create_client(
    payload: ClientCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_module("crm")),
):
    client = Client(tenant_id=current_user.tenant_id, **payload.model_dump())
    db.add(client)
    db.commit()
    db.refresh(client)
    return client


@router.get("/clients")
def list_clients(db: Session = Depends(get_db), current_user: User = Depends(require_module("crm"))):
    return db.query(Client).filter(Client.tenant_id == current_user.tenant_id).all()
