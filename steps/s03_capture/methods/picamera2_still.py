from core.registry import register_method
from core.context import PipelineContext
from core.session import CaptureSession
from steps.s03_capture.models import CaptureOutput


@register_method(
    step="s03_capture",
    name="picamera2_still",
    display_name="PiCamera2 Still Capture",
)
def capture_picamera2_still(ctx: PipelineContext) -> PipelineContext:
    cam = CaptureSession.get().retrieve("camera")
    if cam is None:
        raise RuntimeError("No camera in session.")

    cam.start()
    array = cam.capture_array()
    cam.stop()

    session_key = f"capture_{ctx.timestamp}"
    CaptureSession.get().store(session_key, array)

    output = CaptureOutput(
        width=array.shape[1],
        height=array.shape[0],
        channels=array.shape[2] if len(array.shape) > 2 else 1,
        dtype=str(array.dtype),
        session_key=session_key,
    )

    ctx.set_step_output("s03_capture", output)
    return ctx