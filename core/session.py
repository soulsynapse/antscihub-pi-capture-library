from typing import Any, Optional


class CaptureSession:
    _instance: Optional["CaptureSession"] = None

    def __init__(self):
        self._resources: dict[str, Any] = {}

    @classmethod
    def get(cls) -> "CaptureSession":
        if cls._instance is None:
            cls._instance = CaptureSession()
        return cls._instance

    def store(self, key: str, resource: Any):
        self._resources[key] = resource

    def retrieve(self, key: str) -> Any:
        return self._resources.get(key)

    def release(self, key: str):
        resource = self._resources.pop(key, None)
        if resource is not None and hasattr(resource, "close"):
            resource.close()

    def release_all(self):
        for key in list(self._resources.keys()):
            self.release(key)