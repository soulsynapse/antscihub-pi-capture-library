from pydantic import BaseModel
from typing import Optional


class PipelineContext(BaseModel):
    step_outputs: dict[str, BaseModel] = {}
    mode: str = "capture"
    profile_name: Optional[str] = None
    timestamp: str = ""

    class Config:
        arbitrary_types_allowed = True

    def set_step_output(self, step_name: str, output: BaseModel):
        self.step_outputs[step_name] = output

    def get_step_output(self, step_name: str) -> Optional[BaseModel]:
        return self.step_outputs.get(step_name)