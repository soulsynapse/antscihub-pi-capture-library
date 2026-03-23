from core.registry import register_method
from core.context import PipelineContext
from core.session import CaptureSession
from steps.s01_register_hardware.models import RegisterHardwareOutput


class MockCamera:
    def __init__(self):
        self.camera_idx = 0
        self.camera_properties = {
            "Model": "mock_sensor_v1",
            "Location": "/dev/null",
            "PixelArraySize": (1920, 1080),
        }
        self._config = None
        self._running = False

    def create_still_configuration(self, main=None, **kwargs):
        return {"main": main or {"size": (1920, 1080), "format": "RGB888"}}

    def configure(self, config):
        self._config = config

    def start(self):
        self._running = True

    def stop(self):
        self._running = False

    def capture_array(self):
        import numpy as np

        size = self._config["main"]["size"] if self._config else (1920, 1080)
        h, w = size[1], size[0]
        array = np.zeros((h, w, 3), dtype=np.uint8)
        array[:, :, 0] = np.linspace(0, 255, w, dtype=np.uint8)
        array[:, :, 1] = np.linspace(0, 255, h, dtype=np.uint8).reshape(-1, 1)
        return array

    def close(self):
        self._running = False


@register_method(
    step="s01_register_hardware",
    name="mock_camera",
    display_name="Mock Camera (Testing)",
)
def register_mock(ctx: PipelineContext) -> PipelineContext:
    cam = MockCamera()

    output = RegisterHardwareOutput(
        model="mock_sensor_v1",
        address="/dev/null",
        interface="mock",
        device_id="camera-mock-0",
    )

    CaptureSession.get().store("camera", cam)
    ctx.set_step_output("s01_register_hardware", output)
    return ctx