import os
from pathlib import Path
from core.registry import register_method
from core.context import PipelineContext
from core.session import CaptureSession
from steps.s03_capture.models import CaptureOutput
from steps.s04_output.models import OutputResult


@register_method(
    step="s04_output",
    name="save_to_disk",
    display_name="Save to Disk (PNG)",
)
def save_to_disk(ctx: PipelineContext) -> PipelineContext:
    from PIL import Image
    import numpy as np

    capture: CaptureOutput = ctx.get_step_output("s03_capture")
    if capture is None:
        raise RuntimeError("No capture data. Did capture step run?")

    array: np.ndarray = CaptureSession.get().retrieve(capture.session_key)
    if array is None:
        raise RuntimeError(
            f"Image array not found in session at key '{capture.session_key}'"
        )

    output_dir = Path(__file__).resolve().parents[3] / "output"
    output_dir.mkdir(exist_ok=True)

    filename = f"capture_{ctx.timestamp.replace(':', '-')}.png"
    file_path = output_dir / filename

    img = Image.fromarray(array)
    img.save(str(file_path))

    file_size = os.path.getsize(file_path)

    CaptureSession.get().release(capture.session_key)

    output = OutputResult(
        file_path=str(file_path),
        file_size_bytes=file_size,
        format="png",
    )

    ctx.set_step_output("s04_output", output)
    return ctx