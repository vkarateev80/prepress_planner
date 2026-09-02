# -*- coding: utf-8 -*-
import re
import zlib

data = open("fixtures/petlya.pdf", "rb").read()
# объект 10: ищем "10 0 obj" ... "endobj", затем stream...endstream
i = data.find(b"10 0 obj")
j = data.find(b"endobj", i)
body = data[i:j]
s = body.find(b"stream")
e = body.find(b"endstream")
raw = body[s + len(b"stream"):e]
if raw[:2] == b"\r\n":
    raw = raw[2:]
elif raw[:1] == b"\n":
    raw = raw[1:]
print("raw len", len(raw), "first bytes", raw[:6].hex())
for wb in [-15, 15]:
    try:
        out = zlib.decompress(raw, wb)
        print("wbits", wb, "OK len", len(out), "head:", out[:120])
    except Exception as ex:
        print("wbits", wb, "FAIL", type(ex).__name__, str(ex)[:80])
