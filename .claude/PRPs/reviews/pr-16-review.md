# PR Review: #16 — feat: timer cadence comes from the manifest

**Reviewed**: 2026-09-06 · **Decision**: APPROVE

Small, policy-plumbing change with one safety property worth naming: an
invalid `OnCalendar` is refused by `systemd-analyze calendar` *before* any
unit file is written, and the test pins that the existing unit is
byte-identical afterwards. Defaults are unchanged so existing installs are
unaffected until an operator opts in. The `XDG_CONFIG_HOME` change is a
correctness fix in its own right (systemd's rule), found because overriding
`HOME` in the test hid user-site PyYAML — the same "test environment is not
the real one" class as #10.

278/278; mutation (hardcode the old cadence) fails exactly the two new
assertions.
