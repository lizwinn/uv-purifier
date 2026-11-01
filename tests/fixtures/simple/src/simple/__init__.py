from importlib.metadata import version

import attrs
import docopt
from markupsafe import _speedups


def main():
    # _speedups is markupsafe's compiled extension, which only the wheel for
    # this platform has.
    escaped = _speedups._escape_inner("<nix>")
    print(
        f"simple attrs={attrs.__version__} docopt={docopt.__version__}"
        f" markupsafe={version('markupsafe')} {escaped}"
    )
