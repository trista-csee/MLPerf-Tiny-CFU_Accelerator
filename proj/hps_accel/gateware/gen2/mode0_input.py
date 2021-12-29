# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Fetches data from RAM for input layers of Conv2D ops (Mode 0).

This Mode0 fetcher is used to fetch Conv2D input for the input layers of a
model. These Conv 2D ops have:

- depth 1 input pixels
- 4x4 pixel input
- stride 2
- input width 322
- output width 160

Data is read through the RamMux, allowing two words to be read on every cycle.
"""

from nmigen import Cat, Mux, Signal
from nmigen_cfu.util import SimpleElaboratable

from .ram_mux import RamMux
from .utils import unsigned_upto


class EvenPixelAddressGenerator(SimpleElaboratable):
    """Generates address of even numbered pixels.

    Odd numbered pixels are assumed to be at a two byte offset from the
    preceding even numbered pixel. All addresses are in bytes.

    In practice all addresses produced will be a multiple of words offset from
    base_addr.

    Attributes
    ----------

    base_addr: Signal(18), in
        A base number, added to all results

    addr: Signal(18), out
        The byte address for the current pixel.

    start: Signal(), in
        Starts address generation. Addr will be updated on next cycle.

    next: Signal(), in
        Indicates current address has been used. Address will be produced a
        total of eight times each. On the eighth next toggle, a new address
        will be available on the following cycle.
    """

    # Number of addresses to generate for each row. There 160 output pixels
    # to calculate, but we only output every second address
    NUM_ADDRESSES_X = 80

    # Bytes between rows. Since is stride 2, we skip 2 rows
    INCREMENT_Y = 322 * 2

    def __init__(self):
        self.base_addr = Signal(18)
        self.addr = Signal(18)
        self.start = Signal()
        self.next = Signal()

    def elab(self, m):
        pixel_x = Signal(8)
        pixel_row_begin_addr = Signal(16)
        next_count = Signal(3)

        with m.If(self.next):
            m.d.sync += next_count.eq(next_count + 1)
            with m.If(next_count == 7):
                last_x = pixel_x + 1 == self.NUM_ADDRESSES_X
                with m.If(last_x):
                    m.d.sync += [
                        self.addr.eq(pixel_row_begin_addr),
                        pixel_row_begin_addr.eq(
                            pixel_row_begin_addr + self.INCREMENT_Y),
                        pixel_x.eq(0),
                    ]
                with m.Else():
                    m.d.sync += self.addr.eq(self.addr + 4)
                    m.d.sync += pixel_x.eq(pixel_x + 1)
        with m.If(self.start):
            m.d.sync += [
                self.addr.eq(self.base_addr),
                pixel_row_begin_addr.eq(self.base_addr + self.INCREMENT_Y),
                pixel_x.eq(0),
                next_count.eq(0)
            ]


class ValueReader(SimpleElaboratable):
    """Given an address, reads values from a RamMux.

    Reads six bytes, returning the values as two, 32 bit words.

    Attributes
    ----------

    addr: Signal(18), in
        Address from which to read two values. Expected to be an even number

    ram_mux_phase: Signal(range(4)), out
        The phase provided to the RamMux

    ram_mux_addr: [Signal(14)] * 4, out
        Addresses to send to the RAM Mux

    ram_mux_data: [Signal(32)] * 4, in
        Data as read from addresses provided at previous cycle.

    data_out: [Signal(32)] * 2, out
        Data for each of four pixels.
    """

    def __init__(self):
        self.addr = Signal(18)
        self.ram_mux_phase = Signal(range(4))
        self.ram_mux_addr = [Signal(14, name=f"rm_addr{i}") for i in range(4)]
        self.ram_mux_data = [Signal(32, name=f"rm_data{i}") for i in range(4)]
        self.data_out = [Signal(32, name=f"data_out{i}") for i in range(2)]

    def elab(self, m):
        # This code covers 8 cases, determined by bits 1, 2 and 3 of self.addr.
        # First, bit 2 and 3 are used to select the appropriate ram_mux phase
        # and addresses in order to read the two words containing the required
        # data via channels 0 and 3 of the RAM Mux. Once the two words have been
        # retrieved, six bytes are selected from those two words based on the
        # value of bit 1 of self.addr.

        # Uses just two of the mux channels - 0 and 3
        # For convenience, tie the unused addresses to zero
        m.d.comb += self.ram_mux_addr[1].eq(0)
        m.d.comb += self.ram_mux_addr[2].eq(0)

        # Calculate block addresses of the two words - second word may cross 16
        # byte block boundary
        block = Signal(14)
        m.d.comb += block.eq(self.addr[4:])
        m.d.comb += self.ram_mux_addr[0].eq(block)
        m.d.comb += self.ram_mux_addr[3].eq(
            Mux(self.ram_mux_phase == 3, block + 1, block))

        # Use phase to select the two required words to channels 0 & 3
        m.d.comb += self.ram_mux_phase.eq(self.addr[2:4])

        # Select correct three half words when data is available, on cycle after
        # address received
        byte_sel = Signal(1)
        m.d.sync += byte_sel.eq(self.addr[1])
        d0 = self.ram_mux_data[0]
        d3 = self.ram_mux_data[3]
        dmix = Signal(32)
        m.d.comb += dmix.eq(Cat(d0[16:], d3[:16]))
        with m.If(byte_sel == 0):
            m.d.comb += self.data_out[0].eq(d0)
            m.d.comb += self.data_out[1].eq(dmix)
        with m.Else():
            m.d.comb += self.data_out[0].eq(dmix)
            m.d.comb += self.data_out[1].eq(d3)
