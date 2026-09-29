# Vendored headers for the Blue v2 engine

These are public C headers for libraries Zerm already links statically through the sherpa-onnx XCFrameworks. They're checked in so that the app and CI compile without sherpa-onnx's intermediate build folders.

| Header | Library | Version | License |
|---|---|---|---|
| `onnxruntime_c_api.h`, `onnxruntime_ep_c_api.h` | ONNX Runtime | 1.24.4, the version sherpa-onnx 6faa814 links | MIT, Copyright (c) Microsoft Corporation |
| `espeak-ng/speak_lib.h` | eSpeak NG, the csukuangfj fork | commit f6fed6c58b5e0998b8e68c6610125e2d07d595a7, the version sherpa-onnx links | GPL-3.0-or-later |

Update these whenever `SHERPA_COMMIT` in the Makefile changes the linked versions.
