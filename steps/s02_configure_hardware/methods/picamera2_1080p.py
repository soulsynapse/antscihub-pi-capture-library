from core.registry import register_method
from core.context import PipelineContext
from core.session import CaptureSession
from steps.s02_configure_hardware.models import ConfigureHardwareOutput


@register_method(
    step="s02_configure_hardware",
    name="picamera2_1080p",
    display_name="PiCamera2 1080p @ 30fps",
)
def configure_picamera2_1080p(ctx: PipelineContext) -> PipelineContext:
    cam = CaptureSession.get().retrieve("camera")
    if cam is None:
        raise RuntimeError("No camera in session. Did registration run?")

    config = cam.create_still_configuration(
                main={"size": (1920, 1080), "format": "RGB888"},
    )
    cam.configure(config)

    output = ConfigureHardwareOutput(
        resolution=(1920, 1080),
        format="RGB888",
        framerate=30,
    )

    ctx.set_step_output("s02_configure_hardware", output)
    return ctx