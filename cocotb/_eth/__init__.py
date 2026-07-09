# Minimal vendored subset of cocotbext-eth (MIT, (c) Alex Forencich) — only the
# RMII/GMII PHY models, which are dependency-free (the full package's __init__
# pulls eth_mac.py which needs cocotbext-axi). Lets CI run with just cocotb.
from .rmii import RmiiSource, RmiiSink, RmiiPhy
from .gmii import GmiiFrame
