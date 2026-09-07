# meute triage inbox

The screens PRP-003 says are buildable today, over what PRP-001 already writes.
The runner has no dependency on anything in this directory -- `bin/run.sh`
must succeed on a machine where this venv was never created.

    ./bin/meute tui          # in the terminal
    ./bin/meute web          # the same app in a browser (textual-serve), loopback only

Data comes from `lib/inbox.py dump`; every action goes through `bin/meute`
(promote / dismiss / resolve), so the CLI and the UI cannot disagree.
