import importlib
from pathlib import Path


def _auto_import_methods():
    steps_dir = Path(__file__).resolve().parent

    for step_dir in sorted(steps_dir.iterdir()):
        if not step_dir.is_dir():
            continue
        if step_dir.name.startswith("_"):
            continue

        methods_dir = step_dir / "methods"
        if not methods_dir.is_dir():
            continue

        for method_file in sorted(methods_dir.glob("*.py")):
            if method_file.name.startswith("_"):
                continue

            module_path = (
                f"steps.{step_dir.name}.methods.{method_file.stem}"
            )

            try:
                importlib.import_module(module_path)
            except ImportError as e:
                print(f"  ⚠ Skipped {module_path}: {e}")


_auto_import_methods()