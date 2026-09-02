# -*- coding: utf-8 -*-
import base64
import json
import os
import zlib

data = open("fixtures/petlya_open_artifacts.pdf", "rb").read()
i = data.find(b"8 0 obj")
j = data.find(b"endobj", i)
body = data[i:j]
s = body.find(b"stream")
e = body.find(b"endstream")
raw = body[s + 6:e]
if raw[:2] == b"\r\n":
    raw = raw[2:]
elif raw[:1] == b"\n":
    raw = raw[1:]
expected = zlib.decompress(raw, 15)
out = {"raw_b64": base64.b64encode(raw).decode(),
       "out_b64": base64.b64encode(expected).decode()}
json.dump(out, open("packages/core/test/golden/obj8_orig.json", "w", encoding="utf-8"))
print("saved", len(raw), len(expected))
