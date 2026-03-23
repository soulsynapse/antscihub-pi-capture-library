from pydantic import BaseModel


class CaptureOutput(BaseModel):
    width: int
    height: int
    channels: int
    dtype: str
    session_key: str

    class Config:
        arbitrary_types_allowed = True