#!/usr/bin/env python3
"""
Writes guests/binjgb/roms/battery_test.gb: a 32 KB Game Boy ROM (MBC1 + RAM +
BATTERY, 8 KB RAM) that enables cartridge RAM, writes 0x42 to 0xA000 and
0x43 to 0xA001, disables RAM again and halts in a loop. The ABI tests run it
through the binjgb guest to prove battery RAM reaches eden_storage and comes
back on the next start.

Usage: python3 scripts/abi/make_battery_rom.py [--check]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "guests", "binjgb", "roms", "battery_test.gb")

# the Nintendo logo of the cartridge header (required by real hardware's boot
# ROM; binjgb starts post-boot, it is here so the ROM is well-formed)
LOGO = bytes.fromhex(
    "CEED6666CC0D000B03730083000C000D0008111F8889000EDCCC6EE6DDDDD999"
    "BBBB67636E0EECCCDDDC999FBBB9333E")


def build():
    rom = bytearray(32 * 1024)
    rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])      # nop; jp 0x0150
    rom[0x104:0x134] = LOGO
    rom[0x134:0x143] = b"BATTERYTEST".ljust(15, b"\0")      # title
    rom[0x143] = 0x00                                       # DMG
    rom[0x147] = 0x03                                       # MBC1 + RAM + BATTERY
    rom[0x148] = 0x00                                       # 32 KB ROM
    rom[0x149] = 0x02                                       # 8 KB RAM
    rom[0x14A] = 0x01                                       # non-Japanese
    rom[0x14B] = 0x33
    code = bytes([
        0x3E, 0x0A, 0xEA, 0x00, 0x00,   # ld a, 0x0A ; ld (0x0000), a   RAM enable
        0x3E, 0x42, 0xEA, 0x00, 0xA0,   # ld a, 0x42 ; ld (0xA000), a
        0x3E, 0x43, 0xEA, 0x01, 0xA0,   # ld a, 0x43 ; ld (0xA001), a
        0xAF, 0xEA, 0x00, 0x00,         # xor a      ; ld (0x0000), a   RAM disable
        0x76, 0x00,                     # halt ; nop
        0x18, 0xFC,                     # jr -4 (back to halt)
    ])
    rom[0x150:0x150 + len(code)] = code
    checksum = 0
    for i in range(0x134, 0x14D):
        checksum = (checksum - rom[i] - 1) & 0xFF
    rom[0x14D] = checksum
    total = sum(rom[i] for i in range(len(rom)) if i not in (0x14E, 0x14F)) & 0xFFFF
    rom[0x14E] = total >> 8
    rom[0x14F] = total & 0xFF
    return bytes(rom)


def main():
    data = build()
    if "--check" in sys.argv[1:]:
        ok = os.path.exists(OUT) and open(OUT, "rb").read() == data
        print("make_battery_rom: %s" % ("up to date" if ok else "out of date: " + OUT))
        return 0 if ok else 1
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(data)
    print("make_battery_rom: wrote %s (%d bytes)" % (OUT, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
