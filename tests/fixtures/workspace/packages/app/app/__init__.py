"""The workspace fixture's application."""

__version__ = "2.0.0"

import six
from greeting import greet


def main():
    print(f"{greet('nix')} six={six.__version__}")
