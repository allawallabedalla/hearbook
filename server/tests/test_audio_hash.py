"""Tests for the audio-hash algorithm, docs/ARCHITEKTUR.md section 3.4.

Mandatory tests per the spec:
- same audio data with different tags or name -> same hash
- different audio -> different hash
- ID3v2 with footer
- APEv2 with and without header
- ID3v1 and APEv2 combined
"""

from __future__ import annotations

import struct

import pytest

from faden_server.audio_hash import audio_hash, audio_hash_bytes

from .conftest import requires_ffmpeg, synth_tone


def _syncsafe(n: int) -> bytes:
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def build_id3v2(payload: bytes, *, footer: bool) -> bytes:
    flags = 0x10 if footer else 0x00
    header = b"ID3" + bytes([4, 0]) + bytes([flags]) + _syncsafe(len(payload))
    out = header + payload
    if footer:
        out += b"3DI" + bytes([4, 0]) + bytes([flags]) + _syncsafe(len(payload))
    return out


def build_id3v1() -> bytes:
    return b"TAG" + b"\x00" * 125


def build_ape(item_payload: bytes, *, with_header: bool) -> bytes:
    tag_size = len(item_payload) + 32  # items + footer, excludes header per APEv2 spec
    flags = 0x80000000 if with_header else 0
    footer = (
        b"APETAGEX"
        + struct.pack("<I", 2000)
        + struct.pack("<I", tag_size)
        + struct.pack("<I", 1)
        + struct.pack("<I", flags)
        + b"\x00" * 8
    )
    assert len(footer) == 32
    if with_header:
        header = footer  # same layout
        return header + item_payload + footer
    return item_payload + footer


@pytest.fixture(scope="module")
def base_audio(tmp_path_factory) -> bytes:
    d = tmp_path_factory.mktemp("audio")
    path = synth_tone(d / "base.mp3", segments=[("tone", 0.5)], freq=440)
    return path.read_bytes()


@pytest.fixture(scope="module")
def other_audio(tmp_path_factory) -> bytes:
    d = tmp_path_factory.mktemp("audio2")
    path = synth_tone(d / "other.mp3", segments=[("tone", 0.5)], freq=880)
    return path.read_bytes()


@requires_ffmpeg
def test_same_audio_different_tags_or_name_same_hash(tmp_path, base_audio):
    plain = tmp_path / "plain.mp3"
    plain.write_bytes(base_audio)

    tagged = tmp_path / "very-different-name-with-tags.mp3"
    tagged.write_bytes(build_id3v2(b"\x00" * 40, footer=False) + base_audio + build_id3v1())

    assert audio_hash(plain) == audio_hash(tagged)
    assert audio_hash(plain) == audio_hash_bytes(base_audio)


@requires_ffmpeg
def test_different_audio_different_hash(base_audio, other_audio):
    assert audio_hash_bytes(base_audio) != audio_hash_bytes(other_audio)


@requires_ffmpeg
def test_id3v2_with_footer(tmp_path, base_audio):
    wrapped = build_id3v2(b"\x00" * 64, footer=True) + base_audio
    p = tmp_path / "footer.mp3"
    p.write_bytes(wrapped)
    assert audio_hash(p) == audio_hash_bytes(base_audio)


@requires_ffmpeg
def test_apev2_without_header(tmp_path, base_audio):
    wrapped = base_audio + build_ape(b"\x00" * 20, with_header=False)
    p = tmp_path / "ape_no_header.mp3"
    p.write_bytes(wrapped)
    assert audio_hash(p) == audio_hash_bytes(base_audio)


@requires_ffmpeg
def test_apev2_with_header(tmp_path, base_audio):
    wrapped = base_audio + build_ape(b"\x00" * 20, with_header=True)
    p = tmp_path / "ape_with_header.mp3"
    p.write_bytes(wrapped)
    assert audio_hash(p) == audio_hash_bytes(base_audio)


@requires_ffmpeg
def test_id3v1_and_apev2_combined(tmp_path, base_audio):
    wrapped = base_audio + build_ape(b"\x00" * 20, with_header=False) + build_id3v1()
    p = tmp_path / "combined.mp3"
    p.write_bytes(wrapped)
    assert audio_hash(p) == audio_hash_bytes(base_audio)


@requires_ffmpeg
def test_id3v1_and_apev2_with_header_combined(tmp_path, base_audio):
    wrapped = base_audio + build_ape(b"\x00" * 20, with_header=True) + build_id3v1()
    p = tmp_path / "combined2.mp3"
    p.write_bytes(wrapped)
    assert audio_hash(p) == audio_hash_bytes(base_audio)


def test_streams_in_blocks_not_whole_file(tmp_path, monkeypatch):
    """Boundary detection and hashing must not read the whole file at once."""
    import faden_server.audio_hash as ah

    data = b"ID3" + bytes([4, 0, 0]) + _syncsafe(0) + b"\xff\xfb" + b"\x00" * (3 * ah.BLOCK_SIZE)
    p = tmp_path / "big.mp3"
    p.write_bytes(data)

    max_read = 0

    real_open = open

    class TrackingFile:
        def __init__(self, f):
            self._f = f

        def __getattr__(self, item):
            return getattr(self._f, item)

        def read(self, n=-1):
            nonlocal max_read
            if n is not None and n > 0:
                max_read = max(max_read, n)
            return self._f.read(n)

        def __enter__(self):
            return self

        def __exit__(self, *a):
            self._f.close()

    def tracking_open(*args, **kwargs):
        return TrackingFile(real_open(*args, **kwargs))

    monkeypatch.setattr(ah, "open", tracking_open, raising=False)
    ah.audio_hash(p)
    assert max_read <= ah.BLOCK_SIZE


def test_hex_digest_shape(tmp_path, base_audio):
    p = tmp_path / "a.mp3"
    p.write_bytes(base_audio)
    h = audio_hash(p)
    assert len(h) == 64
    assert all(c in "0123456789abcdef" for c in h)
