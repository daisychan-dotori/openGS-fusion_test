"""Patch vdbfusion setup.py so TBB_ROOT is optional.

The original setup.py reads OPENGS_ENV (the conda env path, which has no TBB
installed) as TBB_ROOT and passes it to cmake, causing TBB lookup to fail.
This patch makes TBB_ROOT optional: it is only passed when explicitly set.
"""
import re
import pathlib

p = pathlib.Path("setup.py")
s = p.read_text()

# Replace the TBB_ROOT block:
#   tbb_root = os.environ.get("OPENGS_ENV") or os.environ.get("TBB_ROOT")
#   if not tbb_root:
#       raise RuntimeError(...)
#   cmake_args.append(f"-DTBB_ROOT={tbb_root}")
# with:
#   tbb_root = os.environ.get("TBB_ROOT")
#   if tbb_root:
#       cmake_args.append(f"-DTBB_ROOT={tbb_root}")
s = re.sub(
    r'tbb_root = os\.environ\.get.*?cmake_args\.append\(f"-DTBB_ROOT=\{tbb_root\}"\)',
    'tbb_root = os.environ.get("TBB_ROOT")\n'
    '        if tbb_root:\n'
    '            cmake_args.append(f"-DTBB_ROOT={tbb_root}")',
    s,
    flags=re.DOTALL,
)

p.write_text(s)
