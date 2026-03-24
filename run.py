#!/usr/bin/env python3
"""
antscihub-pi-capture-library

Usage:
    run.py --profile profiles/basic_picamera2.yaml
    run.py --chain '[{"step":"s01_register_hardware","method":"mock_camera"},...]'
    run.py --list-methods
    run.py --list-profiles
    run.py --verify

Exit codes:
    0 = success
    1 = pipeline error
    2 = bad arguments
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import yaml

# Ensure repo root is on path regardless of working directory
REPO_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_DIR))

# Trigger auto-discovery of all methods
import steps  # noqa: F401

from core.pipeline import Pipeline, PipelineError
from core.session import CaptureSession
from core.registry import list_all_methods


# ---------------------------------------------------------------------------
# MQTT reporting via fleet-publish
# ---------------------------------------------------------------------------

def get_device_id() -> str:
    """Get device ID from environment, falling back to hostname."""
    device_id = os.environ.get("DEVICE_ID", "")
    if not device_id:
        try:
            import socket
            device_id = socket.gethostname()
        except Exception:
            device_id = "unknown-device"
    return device_id


def fleet_publish(event: str, success: bool, message: str, data: dict = None):
    """
    Publish result over MQTT via fleet-publish.
    Falls back to printing if fleet-publish isn't available.
    """
    device_id = get_device_id()

    payload = {
        "schema": "fleet.capture.v1",
        "event": event,
        "service": "antscihub-capture",
        "device_id": device_id,
        "timestamp": int(datetime.now().timestamp()),
        "success": success,
        "message": message,
    }

    if data:
        payload["data"] = data

    payload_json = json.dumps(payload)

    try:
        subprocess.run(
            [
                "fleet-publish",
                "--topic", f"fleet/response/{device_id}",
                "--json", payload_json,
            ],
            check=True,
            capture_output=True,
            timeout=10,
        )
    except FileNotFoundError:
        print(f"  ℹ fleet-publish not available, payload:")
        print(f"    {payload_json}")
    except subprocess.CalledProcessError as e:
        print(f"  ⚠ fleet-publish failed: {e.stderr.decode()}")


# ---------------------------------------------------------------------------
# Pipeline execution
# ---------------------------------------------------------------------------

def run_pipeline(chain: list[tuple[str, str]], mode: str, label: str) -> int:
    """Run a pipeline and report results. Returns exit code."""
    pipeline = Pipeline(chain=chain, mode=mode)

    try:
        ctx = pipeline.run()

        # Collect all step outputs
        outputs = {}
        for step_name, output in ctx.step_outputs.items():
            outputs[step_name] = output.model_dump()

        # Print result
        output_result = ctx.get_step_output("s04_output")
        if output_result:
            print(f"\n  ✓ Image saved to: {output_result.file_path}")
            print(f"  ✓ File size: {output_result.file_size_bytes / 1024:.1f} KB")

        fleet_publish(
            event="capture_complete",
            success=True,
            message=f"Pipeline '{label}' completed",
            data=outputs,
        )

        return 0

    except PipelineError as e:
        print(f"\n  ✗ Pipeline failed: {e}")
        fleet_publish(
            event="capture_failed",
            success=False,
            message=str(e),
            data={"step": e.step, "method": e.method},
        )
        return 1

    except Exception as e:
        print(f"\n  ✗ Unexpected error: {e}")
        fleet_publish(
            event="capture_error",
            success=False,
            message=f"Unexpected: {e}",
        )
        return 1

    finally:
        CaptureSession.get().release_all()


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_run_profile(profile_path: str) -> int:
    """Run pipeline from a YAML profile."""
    # Resolve profile path relative to repo if not absolute
    path = Path(profile_path)
    if not path.is_absolute():
        path = REPO_DIR / path

    if not path.exists():
        print(f"  ✗ Profile not found: {path}")
        return 2

    with open(path, "r") as f:
        profile = yaml.safe_load(f)

    chain = [(entry["step"], entry["method"]) for entry in profile["chain"]]
    mode = profile.get("mode", "capture")
    name = profile.get("name", path.stem)

    print(f"Profile: {name}")
    print(f"Description: {profile.get('description', '')}")

    return run_pipeline(chain, mode, name)


def cmd_run_chain(chain_json: str, mode: str) -> int:
    """Run pipeline from a JSON chain."""
    try:
        chain_list = json.loads(chain_json)
    except json.JSONDecodeError as e:
        print(f"  ✗ Invalid JSON for --chain: {e}")
        return 2

    chain = [(entry["step"], entry["method"]) for entry in chain_list]
    return run_pipeline(chain, mode, "ad-hoc")


def cmd_list_methods() -> int:
    """List all registered methods."""
    all_methods = list_all_methods()
    print("\nRegistered Methods:")
    print("-" * 40)
    for step_name, methods in sorted(all_methods.items()):
        print(f"\n  {step_name}:")
        for method in methods:
            print(f"    - {method}")
    print()
    return 0


def cmd_list_profiles() -> int:
    """List available profiles."""
    profiles_dir = REPO_DIR / "profiles"
    if not profiles_dir.exists():
        print("  No profiles directory found")
        return 1

    print("\nAvailable Profiles:")
    print("-" * 40)
    for f in sorted(profiles_dir.glob("*.yaml")):
        with open(f) as fh:
            data = yaml.safe_load(fh)
        name = data.get("name", f.stem)
        desc = data.get("description", "")
        chain = data.get("chain", [])
        print(f"\n  {f.name}")
        print(f"    Name: {name}")
        print(f"    Description: {desc}")
        print(f"    Steps: {' → '.join(e['method'] for e in chain)}")
    print()
    return 0


def cmd_verify() -> int:
    """
    Boot health check. Verifies:
    - All step modules load
    - At least one method per step is registered
    - Output directory is writable
    Reports result over MQTT.
    """
    print("Running boot verification...")
    issues = []

    # Check methods loaded
    all_methods = list_all_methods()
    if not all_methods:
        issues.append("No methods registered at all")
    else:
        expected_steps = [
            "s01_register_hardware",
            "s02_configure_hardware",
            "s03_capture",
            "s04_output",
        ]
        for step in expected_steps:
            if step not in all_methods:
                issues.append(f"No methods for step '{step}'")
            else:
                print(f"  ✓ {step}: {len(all_methods[step])} method(s)")

    # Check output directory
    output_dir = REPO_DIR / "output"
    if not output_dir.exists():
        try:
            output_dir.mkdir(parents=True)
            print(f"  ✓ Created output directory: {output_dir}")
        except Exception as e:
            issues.append(f"Cannot create output directory: {e}")
    else:
        # Test write
        test_file = output_dir / ".write_test"
        try:
            test_file.write_text("test")
            test_file.unlink()
            print(f"  ✓ Output directory writable: {output_dir}")
        except Exception as e:
            issues.append(f"Output directory not writable: {e}")

    # Check profiles exist
    profiles_dir = REPO_DIR / "profiles"
    profile_count = len(list(profiles_dir.glob("*.yaml"))) if profiles_dir.exists() else 0
    if profile_count == 0:
        issues.append("No profiles found")
    else:
        print(f"  ✓ {profile_count} profile(s) found")

    # Report
    if issues:
        msg = f"Verification failed: {'; '.join(issues)}"
        print(f"\n  ✗ {msg}")
        fleet_publish("verify_failed", False, msg)
        return 1
    else:
        msg = (
            f"Verification passed: {sum(len(m) for m in all_methods.values())} methods, "
            f"{profile_count} profiles"
        )
        print(f"\n  ✓ {msg}")
        fleet_publish("verify_ok", True, msg)
        return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="antscihub-pi-capture-library",
    )
    parser.add_argument(
        "--mode", type=str, default="capture",
        choices=["preview", "capture"],
        help="Pipeline mode (default: capture)",
    )
    parser.add_argument(
        "--list-methods", action="store_true",
        help="List all registered methods",
    )
    parser.add_argument(
        "--list-profiles", action="store_true",
        help="List available profiles",
    )
    parser.add_argument(
        "--verify", action="store_true",
        help="Run boot health check",
    )
    parser.add_argument(
        "--profile", type=str,
        help="Path to a YAML profile file",
    )
    parser.add_argument(
        "--chain", type=str,
        help='JSON array of [{"step":"...","method":"..."}] objects',
    )

    args = parser.parse_args()

    if args.verify:
        return cmd_verify()

    if args.list_methods:
        return cmd_list_methods()

    if args.list_profiles:
        return cmd_list_profiles()

    if args.profile:
        return cmd_run_profile(args.profile)

    if args.chain:
        return cmd_run_chain(args.chain, args.mode)

    # No arguments — print help
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())