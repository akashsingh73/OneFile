"""An independent age (age-encryption.org/v1) decryptor for passphrase-locked files, written from
the spec in plain Python (scrypt from hashlib; ChaCha20-Poly1305, HKDF and the rest by hand), to
check that what OneFile writes opens with any age implementation.

Usage: python3 age_reference.py FILE.age PASSWORD OUTPUT
(PASSWORD as "hex:…" gives its UTF-8 bytes exactly: some ways of starting a program change accents.)
"""
import base64
import hashlib
import hmac
import struct
import sys

MASK = 0xFFFFFFFF


def rotl(value, count):
    return ((value << count) & MASK) | (value >> (32 - count))


def quarter(s, a, b, c, d):
    s[a] = (s[a] + s[b]) & MASK; s[d] = rotl(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & MASK; s[b] = rotl(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b]) & MASK; s[d] = rotl(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & MASK; s[b] = rotl(s[b] ^ s[c], 7)


def chacha_block(key, counter, nonce):
    state = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574] + list(struct.unpack("<8I", key)) \
        + [counter] + list(struct.unpack("<3I", nonce))
    work = state[:]
    for _ in range(10):
        quarter(work, 0, 4, 8, 12); quarter(work, 1, 5, 9, 13); quarter(work, 2, 6, 10, 14); quarter(work, 3, 7, 11, 15)
        quarter(work, 0, 5, 10, 15); quarter(work, 1, 6, 11, 12); quarter(work, 2, 7, 8, 13); quarter(work, 3, 4, 9, 14)
    return struct.pack("<16I", *[(a + b) & MASK for a, b in zip(work, state)])


def chacha20(key, counter, nonce, data):
    out = bytearray()
    for start in range(0, len(data), 64):
        stream = chacha_block(key, counter + start // 64, nonce)
        out += bytes(x ^ y for x, y in zip(data[start:start + 64], stream))
    return bytes(out)


def poly1305(key, message):
    r = int.from_bytes(key[:16], "little") & 0x0FFFFFFC0FFFFFFC0FFFFFFC0FFFFFFF
    s = int.from_bytes(key[16:], "little")
    p = (1 << 130) - 5
    acc = 0
    for start in range(0, len(message), 16):
        acc = (acc + int.from_bytes(message[start:start + 16] + b"\x01", "little")) * r % p
    return ((acc + s) % (1 << 128)).to_bytes(16, "little")


def open_sealed(key, nonce, sealed):
    ciphertext, tag = sealed[:-16], sealed[-16:]
    one_time = chacha_block(key, 0, nonce)[:32]
    pad = b"\x00" * (-len(ciphertext) % 16)
    if not hmac.compare_digest(poly1305(one_time, ciphertext + pad + struct.pack("<QQ", 0, len(ciphertext))), tag):
        raise ValueError("a piece doesn't authenticate")
    return chacha20(key, 1, nonce, ciphertext)


def hkdf(key, salt, info, length=32):
    prk = hmac.new(salt if salt else b"\x00" * 32, key, hashlib.sha256).digest()
    out, block = b"", b""
    for counter in range(1, -(-length // 32) + 1):
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
    return out[:length]


def unbase64(text):
    return base64.b64decode(text + "=" * (-len(text) % 4))


def decrypt(data, password):
    lines, at = [], 0
    while True:
        end = data.index(b"\n", at)
        lines.append((data[at:end].decode(), end + 1))
        if data[at:at + 3] == b"---":
            break
        at = end + 1
    assert lines[0][0] == "age-encryption.org/v1", "not an age file"
    kind, salt, factor = lines[1][0][3:].split(" ")
    assert kind == "scrypt", "not locked with a password"
    body = "".join(text for text, _ in lines[2:-1])
    secret = bytes.fromhex(password[4:]) if password.startswith("hex:") else password.encode()
    wrap_key = hashlib.scrypt(secret, salt=b"age-encryption.org/v1/scrypt" + unbase64(salt),
                              n=1 << int(factor), r=8, p=1, dklen=32, maxmem=1 << 30)
    file_key = open_sealed(wrap_key, b"\x00" * 12, unbase64(body))
    covered = data[:lines[-2][1] + 3]
    mac = hmac.new(hkdf(file_key, b"", b"header"), covered, hashlib.sha256).digest()
    assert hmac.compare_digest(mac, unbase64(lines[-1][0][4:])), "the header's MAC is wrong"
    start = lines[-1][1]
    payload_key = hkdf(file_key, data[start:start + 16], b"payload")
    sealed = data[start + 16:]
    out, index, size = bytearray(), 0, 65536 + 16
    while True:
        piece = sealed[index * size:(index + 1) * size]
        last = (index + 1) * size >= len(sealed)
        nonce = index.to_bytes(11, "big") + (b"\x01" if last else b"\x00")
        out += open_sealed(payload_key, nonce, piece)
        index += 1
        if last:
            return bytes(out)


if __name__ == "__main__":
    source, password, target = sys.argv[1:4]
    with open(source, "rb") as handle:
        plain = decrypt(handle.read(), password)
    with open(target, "wb") as handle:
        handle.write(plain)
