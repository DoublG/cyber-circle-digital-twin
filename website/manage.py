#!/usr/bin/env python3
"""Django's command-line utility for the registration and scoreboard website."""
import os
import sys

if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "cybersite.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
