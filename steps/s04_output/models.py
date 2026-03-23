from pydantic import BaseModel


class OutputResult(BaseModel):
    file_path: str
    file_size_bytes: int
    format: str