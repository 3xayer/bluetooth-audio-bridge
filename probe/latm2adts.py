#!/usr/bin/env python3
"""Offline check of the A2DP AAC capture: parse LATM AudioMuxElements (muxConfigPresent=1, as sent
by Android's A2DP AAC encoder), print the stream config, and write the raw AAC frames as ADTS so
macOS tools (afconvert / afplay) can decode them.

Usage: latm2adts.py capture.aac.pkts out.aac
Capture format: per packet [u16 big-endian length][RTP payload].
"""
import struct
import sys


class Bits:
    def __init__(self, data):
        self.d, self.pos = data, 0

    def read(self, n):
        v = 0
        for _ in range(n):
            byte = self.d[self.pos >> 3]
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def latm_value(self):
        n = self.read(2)
        v = 0
        for _ in range(n + 1):
            v = (v << 8) | self.read(8)
        return v


def parse_asc(b):
    start = b.pos
    aot = b.read(5)
    sfi = b.read(4)
    sr = b.read(24) if sfi == 0xF else None
    ch = b.read(4)
    b.read(3)  # GASpecificConfig: frameLengthFlag, dependsOnCoreCoder, extensionFlag
    return dict(aot=aot, sfi=sfi, ch=ch, sr=sr), b.pos - start


def parse_element(payload, cfg):
    b = Bits(payload)
    if not b.read(1):  # useSameStreamMux == 0 -> StreamMuxConfig follows
        ver = b.read(1)
        ver_a = b.read(1) if ver else 0
        assert ver_a == 0, "audioMuxVersionA=1 not supported"
        if ver:
            cfg["taraBufferFullness"] = b.latm_value()
        cfg["allSame"] = b.read(1)
        cfg["numSubFrames"] = b.read(6)
        cfg["numProgram"] = b.read(4)
        cfg["numLayer"] = b.read(3)
        assert cfg["numProgram"] == 0 and cfg["numLayer"] == 0, "multi program/layer not supported"
        if ver:
            asc_len = b.latm_value()
            asc, used = parse_asc(b)
            b.read(asc_len - used)  # fill bits
        else:
            asc, _ = parse_asc(b)
        cfg["asc"] = asc
        cfg["frameLengthType"] = b.read(3)
        assert cfg["frameLengthType"] == 0, "only frameLengthType 0 supported"
        cfg["latmBufferFullness"] = b.read(8)
        cfg["otherDataPresent"] = b.read(1)
        if cfg["otherDataPresent"]:
            cfg["otherDataLenBits"] = b.latm_value() if ver else None
        cfg["crc"] = b.read(1)
        if cfg["crc"]:
            b.read(8)
    elif "asc" not in cfg:
        raise ValueError("useSameStreamMux before any StreamMuxConfig")

    frames = []
    for _ in range(cfg["numSubFrames"] + 1):
        length = 0
        while True:
            t = b.read(8)
            length += t
            if t != 255:
                break
        frames.append(bytes(b.read(8) for _ in range(length)))
    return frames


def adts_header(asc, frame_len):
    total = frame_len + 7
    profile = asc["aot"] - 1
    return bytes([
        0xFF, 0xF1,
        (profile << 6) | (asc["sfi"] << 2) | (asc["ch"] >> 2),
        ((asc["ch"] & 3) << 6) | (total >> 11),
        (total >> 3) & 0xFF,
        ((total & 7) << 5) | 0x1F,
        0xFC,
    ])


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    cfg, pos, pkts, nframes, sizes = {}, 0, 0, 0, []
    with open(dst, "wb") as out:
        while pos + 2 <= len(data):
            (n,) = struct.unpack(">H", data[pos:pos + 2])
            payload = data[pos + 2:pos + 2 + n]
            pos += 2 + n
            pkts += 1
            for f in parse_element(payload, cfg):
                out.write(adts_header(cfg["asc"], len(f)) + f)
                nframes += 1
                sizes.append(len(f))
    print("config:", cfg)
    print(f"packets={pkts} frames={nframes} frame bytes min/avg/max = "
          f"{min(sizes)}/{sum(sizes) // len(sizes)}/{max(sizes)}")


if __name__ == "__main__":
    main()
