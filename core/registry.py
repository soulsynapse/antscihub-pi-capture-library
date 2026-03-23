from typing import Callable

_METHOD_REGISTRY: dict[str, dict[str, dict]] = {}


def register_method(step: str, name: str, display_name: str = ""):
    def decorator(func: Callable):
        if step not in _METHOD_REGISTRY:
            _METHOD_REGISTRY[step] = {}

        _METHOD_REGISTRY[step][name] = {
            "function": func,
            "display_name": display_name or name,
        }
        return func

    return decorator


def get_methods_for_step(step: str) -> dict[str, dict]:
    return _METHOD_REGISTRY.get(step, {})


def get_method(step: str, name: str) -> Callable:
    methods = _METHOD_REGISTRY.get(step)
    if not methods:
        raise KeyError(f"No methods registered for step '{step}'")
    entry = methods.get(name)
    if not entry:
        available = list(methods.keys())
        raise KeyError(
            f"Method '{name}' not found for step '{step}'. "
            f"Available: {available}"
        )
    return entry["function"]


def list_all_methods() -> dict[str, list[str]]:
    return {step: list(methods.keys()) for step, methods in _METHOD_REGISTRY.items()}