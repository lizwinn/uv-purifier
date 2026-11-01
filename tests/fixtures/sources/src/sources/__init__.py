import attrs
import idna
import localdir
import localsdist
import localwheel
import six


def main():
    print(
        f"attrs={attrs.__version__} six={six.__version__} idna={idna.__version__}"
        f" {localdir.VALUE} {localsdist.VALUE} {localwheel.VALUE}"
    )
