# Library navigation after offload — October 6, 2026

Version 1.7.19 selected the destination folder with the largest file count. A batch
with 20 photos from September 29 and one from October 6 therefore opened September 29.
Equal file counts also depended on dictionary iteration order. The new regression
failed on the old code with `/fixture/nas/2026/09/29` instead of the expected October 6.

Version 1.7.20 opens the newest verified capture day **in the completed batch**.
The saved destination folder is retained rather than rebuilding a path, so custom
layouts and resolved filenames remain correct. Folder dates determine chronology;
saved capture/creation/modification metadata provides a fallback for unrecognized paths.
Only NAS-verified, skipped-duplicate, and wiped records participate. No new filesystem
or network reads are needed to choose the folder; each unique folder is parsed once.

| Regression | Result |
| --- | --- |
| One newer photo wins over 20 older photos | PASS; failed before the fix |
| File order and equal counts across a year boundary | PASS |
| Legacy records, seven presets, and non-alphabetical custom month folders | PASS |
| Wiped/duplicate records included; unfinished/failed copies excluded; saved path retained | PASS |
| Empty or unverified batch does not request navigation | PASS |
| Library loads the newest folder's photos while older navigation is pending | PASS |

Full local suite: **182 passed, one optional live-provider test skipped, zero failures**.
The navigation test uses generated temporary directories with isolated Library metadata.
It exercises the same `openPinned` operation used by new and existing Library windows.
It does not claim a physical-card transfer or graphical end-to-end test. The existing
CI workflow also runs all ten disposable transfer/erasure integration modes on each push.
