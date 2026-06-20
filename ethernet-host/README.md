# ethernet-host

Host-side tools to drive the chip's Ethernet UDP→memory bridge over plain UDP.
See `../reference/vivado_nexys/docs/protocol.md` for the wire format.

## Against real hardware
NIC cabled to the board, host static IP `192.168.1.10/24`:
```
python dma.py ping
python dma.py write 0x0 deadbeefcafef00d
python dma.py read  0x0 16
python dma.py test --size 8192          # write random, read back, verify
```

## Against simulation
A cocotb UDP-socket bridge (`../cocotb/sim_udp_bridge.py`, M-later) forwards real
UDP datagrams into the simulated RMII MAC so the *same* `dma.py` drives the sim:
```
# terminal 1: start the sim bridge (prints the local UDP port it listens on)
# terminal 2:
python dma.py --ip 127.0.0.1 --port <bridge_port> test --size 256
```
