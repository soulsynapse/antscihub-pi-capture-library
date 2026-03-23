from pydantic import BaseModel


class ConfigureHardwareOutput(BaseModel):
    resolution: tuple[int, int]
    format: str
    framerate: int