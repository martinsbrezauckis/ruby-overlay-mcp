from pydantic import BaseModel, EmailStr, Field


class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"


class LoginRequest(BaseModel):
    tenant_slug: str
    email: EmailStr
    password: str
    otp_code: str | None = None


class UserCreate(BaseModel):
    email: EmailStr
    full_name: str
    password: str = Field(min_length=8)
    is_admin: bool = False
    modules: list[str] = ["crm", "inventory", "invoices"]


class UserOut(BaseModel):
    id: int
    email: EmailStr
    full_name: str
    is_admin: bool
    modules: list[str]
    two_factor_enabled: bool


class TranslationCreate(BaseModel):
    language_code: str
    key: str
    value: str


class ApiCredentialCreate(BaseModel):
    name: str
    value: str


class CompanyCreate(BaseModel):
    name: str
    registration_number: str = ""
    vat_number: str = ""
    address: str = ""


class ClientCreate(BaseModel):
    full_name: str
    email: str = ""
    phone: str = ""
    commentary: str = ""
    company_id: int | None = None


class InventoryItemCreate(BaseModel):
    sku: str
    name: str
    quantity: int = 0
    unit_price: float = 0.0


class InvoiceCreate(BaseModel):
    invoice_number: str
    direction: str
    client_id: int | None = None
    total_amount: float = 0.0
    currency: str = "EUR"
    format: str = "json"
    raw_payload: str = ""


class TwoFactorSetupResponse(BaseModel):
    provisioning_uri: str


class TwoFactorVerifyRequest(BaseModel):
    otp_code: str
