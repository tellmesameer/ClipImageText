# Upstream Attributions

ClipText builds upon and adapts code from the following open-source projects:

## 1. clipboard (`Kelsiito/clipboard`)

- **Repository**: [https://github.com/Kelsiito/clipboard](https://github.com/Kelsiito/clipboard)
- **License**: MIT License (Copyright © 2026 Kelsiito)
- **Used For**: Baseline native macOS clipboard manager architecture:
  - Local encrypted persistence (`SecureLocalStorage.swift`)
  - Clipboard change observation and transient filtering (`PasteboardMonitor.swift`)
  - In-memory and disk item storage with deduplication (`ClipboardStore.swift`)
  - Carbon global hotkey registration (`GlobalHotKey.swift`)
  - History popover UI and settings interface (`ClipboardPanelController.swift`, `SettingsView.swift`)
  - Unit test suite (`ClipboardTests.swift`)

### Full License Text:
```text
MIT License

Copyright (c) 2026 Kelsiito

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 2. TextGrab (`arsh342/TextGrab`)

- **Repository**: [https://github.com/arsh342/TextGrab](https://github.com/arsh342/TextGrab)
- **License**: MIT License (Copyright © 2026 arsh342)
- **Used For**: Reference implementation for screen selection overlay, ScreenCaptureKit capture pipeline, and Apple Vision OCR processing.

### Full License Text:
```text
MIT License

Copyright (c) 2026 arsh342

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. Klip (`tamibot/klip`)

- **Repository**: [https://github.com/tamibot/klip](https://github.com/tamibot/klip)
- **License**: Apache-2.0 (Copyright 2026 Martin Velasco O.)
- **Used For**: Architecture reference for clean separation of capture, storage, and UI layers.
