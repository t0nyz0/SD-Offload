# NAS verification incident and v1.7.14 validation

## Actual cause

The reported 100% / “verifying on NAS” screen was misleading. The live v1.7.13 journal showed repeated `ioError(errno: 45, stage: "rename on NAS")` failures while other files remained uploading. The destination was SMB, with two upload workers and no secondary backup. Darwin's exclusive-rename extension was rejected by the share. The 1.7.13 safety fix introduced this compatibility regression; the earlier local fixtures did not exercise the SMB transport.

A disposable capability probe confirmed that hard-link promotion was also unsupported, while exclusive file creation preserved an existing destination. The original six-file attempt ended unsuccessfully; no successful offload is claimed for those user files.

## Fix

Network destinations now write through atomic exclusive creation (`O_CREAT | O_EXCL`) instead of unsupported exclusive rename. Existing backups cannot be truncated by this path. Local supported filesystems retain hidden partial files and exclusive rename. SHA-256 read-back and all final erasure gates remain enabled. Unsupported operations fail without repeatedly re-uploading the same bytes.

Network destination names may be visible during copying. Only a verified journal state makes a file safe. A process crash can leave an unfinished network copy; retrying preserves it and chooses a collision-safe name instead of overwriting it.

Verification has its own progress: completed files, bytes read, read speed, current file, estimated check time, and a message after ten seconds without reported read progress. Hash callbacks occur every 1 MiB. Upload retries remain labeled “Saving to NAS,” not “verifying,” and the headline cannot say 100% before completion. Final checks continue emitting progress and support cancellation.

## Validation

- 150 automated tests discovered: **149 passed, one optional live-provider test skipped, zero failures**.
- All ten existing disposable transfer harness modes passed.
- Live SMB primitive probe: a generated 4 MiB file wrote in approximately 2.07 seconds and read back uncached in 0.47 seconds; SHA-256 matched. A second exclusive creation failed with EEXIST and left the first file intact.
- Full SMB session fixture: twelve generated photos copied and verified in about 1.9 seconds, including four collision-suffixed names, final destination checks, fake-card erasure, preservation of the fixture's system folder, and retained local recovery copies. The test used a unique hidden directory on the real share and a temporary fake card; no real card or personal photo was erased.
- The first full-share test correctly stopped at the mount-root identity guard because its destination was an isolated subdirectory. The harness now explicitly enables a restricted test-only subdirectory seam; normal application validation still requires the exact configured mount root.
- Native demo UI inspection confirmed the final check's percentage, byte/file counters, current filename, measured-speed display, remaining-time label, and Stop verification accessibility label. This UI check is a simulation, not evidence that the original user transfer succeeded.

Small synthetic timings demonstrate compatibility, not a throughput promise for RAW files, large cards, Wi-Fi conditions, or every SMB server. Physical card erasure was not used as a development test.
