from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import Response
from sqlalchemy.orm import Session

from ..db import get_db
from ..deps import require_module
from ..models import Invoice, User
from ..schemas import InvoiceCreate

router = APIRouter(prefix="/invoices", tags=["invoices"])
SUPPORTED_FORMATS = {"json", "xml", "csv", "pdf"}


@router.post("")
def create_invoice(
    payload: InvoiceCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_module("invoices")),
):
    if payload.direction not in {"incoming", "outgoing"}:
        raise HTTPException(status_code=400, detail="direction must be incoming/outgoing")
    if payload.format not in SUPPORTED_FORMATS:
        raise HTTPException(status_code=400, detail="Unsupported format")
    invoice = Invoice(tenant_id=current_user.tenant_id, **payload.model_dump())
    db.add(invoice)
    db.commit()
    db.refresh(invoice)
    return invoice


@router.get("")
def list_invoices(db: Session = Depends(get_db), current_user: User = Depends(require_module("invoices"))):
    return db.query(Invoice).filter(Invoice.tenant_id == current_user.tenant_id).all()


@router.post("/import")
async def import_invoice(
    direction: str,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_module("invoices")),
):
    ext = file.filename.split(".")[-1].lower()
    if ext not in SUPPORTED_FORMATS:
        raise HTTPException(status_code=400, detail="Unsupported import format")
    if direction not in {"incoming", "outgoing"}:
        raise HTTPException(status_code=400, detail="direction must be incoming/outgoing")

    content = await file.read()
    invoice = Invoice(
        tenant_id=current_user.tenant_id,
        invoice_number=f"IMP-{file.filename}",
        direction=direction,
        format=ext,
        raw_payload=content.decode(errors="ignore"),
    )
    db.add(invoice)
    db.commit()
    return {"status": "imported", "id": invoice.id, "format": ext}


@router.get("/{invoice_id}/export")
def export_invoice(
    invoice_id: int,
    format: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_module("invoices")),
):
    if format not in SUPPORTED_FORMATS:
        raise HTTPException(status_code=400, detail="Unsupported export format")
    invoice = db.query(Invoice).filter(Invoice.id == invoice_id, Invoice.tenant_id == current_user.tenant_id).first()
    if not invoice:
        raise HTTPException(status_code=404, detail="Invoice not found")
    media_types = {
        "json": "application/json",
        "xml": "application/xml",
        "csv": "text/csv",
        "pdf": "application/pdf",
    }
    payload = invoice.raw_payload or f"Invoice {invoice.invoice_number}"
    return Response(content=payload.encode(), media_type=media_types[format])
