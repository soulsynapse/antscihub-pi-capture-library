from pydantic import BaseModel


class RegisterHardwareOutput(BaseModel):
    model: str          # e.g. "imx477"
    address: str        # e.g. "/dev/video0" or "/base/soc/i2c0mux/i2c@1/imx477@1a"
    interface: str      # e.g. "csi" or "usb"
    device_id: str      # e.g. "camera-0"