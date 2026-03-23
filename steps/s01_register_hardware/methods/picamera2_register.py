from core.registry import register_method
from core.context import PipelineContext
from core.session import CaptureSession
from steps.s01_register_hardware.models import RegisterHardwareOutput


@register_method(
    step="s01_register_hardware",
    name="picamera2",
    display_name="PiCamera2 (CSI)",
)
def register_picamera2(ctx: PipelineContext) -> PipelineContext:
    from picamera2 import Picamera2

    cam = Picamera2()
    props = cam.camera_properties

    output = RegisterHardwareOutput(
        model=props.get("Model", "unknown"),
        address=str(props.get("Location", "unknown")),
        interface="csi",
        device_id=f"camera-{cam.camera_idx}",
    )

    CaptureSession.get().store("camera", cam)
    ctx.set_step_output("s01_register_hardware", output)
    return ctx