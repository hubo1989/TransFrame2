# W02 Recognize and translate (OCR-*, TRN-*, RES-*, N-01…N-04)

**Preconditions:** at least one translation engine configured in Settings › Engines; Fixtures with mixed text open on screen.

| # | Step | Expected | Pass |
|---|---|---|---|
| 1 | Select text region, press T | Drawer opens with stages, then bilingual rows grouped by visual line | ☐ |
| 2 | Toggle "Show Translation on Image" | Translation drawn below the original; switch to "Replace Original" | ☐ |
| 3 | Copy, save and pin | All three outputs contain the drawn translation | ☐ |
| 4 | Disconnect network, retranslate with a cloud-first chain | Falls back to the next engine; provenance shows the engine used | ☐ |
| 5 | Start a slow translation, press Cancel | Stops immediately; no fallback engine is called | ☐ |
| 6 | Compare mode with 3 engines | Switch engines in the drawer without re-translating; failures shown per engine | ☐ |
| 7 | Capture text containing an API key with a cloud engine | Key masked before sending; footer offers "Undo and Resend" | ☐ |
| 8 | Open History | The translation is there with a thumbnail | ☐ |
