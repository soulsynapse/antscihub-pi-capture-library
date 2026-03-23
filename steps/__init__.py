"""
Import all step packages so their methods get registered
via the @register_method decorator.
"""
import steps.s01_register_hardware
import steps.s02_configure_hardware
import steps.s03_capture
import steps.s04_output