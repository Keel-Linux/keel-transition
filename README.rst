================
keel-transition
================

The migration path for a machine already running TurnKey Linux 19.0
(BRIEF section 7). Two binary packages, built from this one source tree:

``keel-archive-keyring``
    The project's OpenPGP public key and nothing else. No maintainer
    script, no apt source, no change to apt's configuration.

``keel-transition``
    ``/usr/sbin/keel-transition`` and its library: survey the appliance,
    write its Keel instance spec, and switch its apt configuration over
    to the Keel Linux archive, in three phases that are each reversible
    and each reported.

Compatible with TurnKey Linux appliances: the tool reads what a 19.0
machine already has and leaves it recoverable.

It installs and upgrades nothing
================================

``keel-transition`` does not run ``apt-get``. It installs nothing and
upgrades nothing. The one package it removes is ``turnkey-keys``, purged
with ``dpkg -P`` after the files it owns are kept for ``--rollback``, so
no key of the TurnKey archive stays trusted. It changes apt sources, two
preferences files and the instance spec. Running ``apt-get update``, and
deciding what to install afterwards, stays with the operator.

That separation is the point. A transition that also upgraded would be
two failures in one command, and ``--rollback`` could only undo one of
them.

The three phases
================

Phase 1: survey, the default
----------------------------

Runs ``keel inspect``, writes ``/etc/keel/instance.yaml`` when that file
is absent (an existing spec is never rewritten), writes the field by
field report, prints every field inspect could not infer, and prints the
three changes ``--apply`` would make. Nothing under ``/etc/apt`` is
changed, and no root privilege is needed.

.. code-block:: console

   # keel-transition
   keel-transition 0.1.0: survey. Nothing under /etc/apt is changed.

   Instance spec
     write         /etc/keel/instance.yaml    written by keel inspect
     report        /var/lib/keel/transition/survey-report.txt
     could not infer, or will not read:
       app.email: not inferred: /etc/inithooks.conf not present
       secrets.root_password: file: /etc/keel/secrets/root_password (not extracted)
     inspect: 20 inferred, 1 not inferred (0 required), 2 secrets to provide

   Archive
     unverified    https://archive.keellinux.org   there is no InRelease and no
                   Release.gpg at .../dists/trixie: that archive is unsigned today
     keyring       /usr/share/keyrings/keel-archive-keyring.gpg
                   key AD0964BE3F09DED469A3B6B2148E951314703180

   What --apply would change
     would create  /etc/apt/sources.list.d/keel.sources
     would create  /etc/apt/preferences.d/keel
     would rename  /etc/apt/sources.list.d/turnkey.list

   keel-transition: --apply would refuse today, exit 4: ...

Phase 2: ``--apply``
--------------------

Writes ``/etc/apt/sources.list.d/keel.sources``:

.. code-block:: ini

   Types: deb
   URIs: https://archive.keellinux.org
   Suites: trixie
   Components: main
   Signed-By: /usr/share/keyrings/keel-archive-keyring.gpg

writes ``/etc/apt/preferences.d/keel``, the same file the apt tooling's
``bin/pin-file`` renders:

.. code-block:: ini

   Package: *
   Pin: release o=Keel Linux
   Pin-Priority: 990

and disables the upstream list by renaming
``/etc/apt/sources.list.d/turnkey.list`` to
``turnkey.list.disabled-by-keel``. The list is renamed, never deleted, so
phase 3 can put the original bytes back. Running ``--apply`` twice leaves
byte identical files.

The pin is on the ``Origin`` of the signed ``Release``, not on the host
name, so it follows the packages to any mirror. 990 is above the 500 of
every other archive, so the Keel build of a package is the candidate
whatever version another archive has, and a ``+keel1`` rebuild is kept
when upstream publishes a higher version. It is below 1000, so apt never
installs a Keel version over a newer installed one: the 1001 this tool
used to write downgraded every package newer on the machine than in the
archive (tracker#23).

What a 19.0 appliance really looks like
```````````````````````````````````````

``turnkey.list`` is the name an appliance of the 18.x lineage carries. An
appliance installed from the 19.0 media has none: its upstream archive
lives in ``/etc/apt/sources.list.d/*.sources``, deb822, in the *same
file* as the Debian stanzas (``sources.sources`` and
``security.sources.sources`` each hold one of each), with
``turnkey-testing.sources`` beside them, an ``/etc/apt/preferences`` that
pins ``o=turnkeylinux`` at 999, and ``turnkey-keys``. Left in place, the
999 pin would beat the Keel pin at 990, so ``--apply`` replaces all of it
(handbook decision 0039: an image takes packages from Debian and the Keel
repository only):

.. code-block:: console

     create   /etc/apt/sources.list.d/debian.sources     deb822, Debian
     create   /etc/apt/sources.list.d/security.sources   deb822, Debian
     rename   /etc/apt/sources.list.d/sources.sources    to sources.sources.disabled-by-keel
     rename   /etc/apt/sources.list.d/security.sources.sources  to ...disabled-by-keel
     rename   /etc/apt/sources.list.d/turnkey-testing.sources   to ...disabled-by-keel
     rename   /etc/apt/preferences                       the o=turnkeylinux pin, to preferences.disabled-by-keel
     purge    turnkey-keys                               dpkg -P, its files kept in /var/lib/keel/transition

Debian's files keep the suites and components the appliance's own Debian
stanzas had. The TurnKey files are renamed only once Debian's are
written, so Debian is never left without a source. Each of these is a
refusal instead, and then nothing is purged: a ``debian.sources`` or
``security.sources`` this tool did not write, an ``/etc/apt/preferences``
with pins besides TurnKey's, or a TurnKey stanza in a file this tool does
not know.

Phase 3: ``--rollback``
-----------------------

Undoes exactly what ``--apply`` did and nothing else. Every renamed file
is renamed back, byte for byte; the files this tool wrote are removed; the
files ``turnkey-keys`` owned are put back where they were, and the run
says to reinstall the package (``apt-get update && apt-get install
turnkey-keys``) so dpkg owns them again. A file at a path this tool writes
that ``keel-transition`` did not write is left alone, reported, and the
run exits 7. The instance spec is left in place: it is yours.

.. code-block:: console

   # keel-transition --rollback
   # diff -r /etc/apt.before /etc/apt && echo identical
   identical

The unsigned archive
====================

Before it changes anything, ``--apply`` fetches
``dists/<suite>/InRelease`` from the archive over IPv6, or ``Release``
and ``Release.gpg``, and verifies the signature with ``gpgv`` against
``/usr/share/keyrings/keel-archive-keyring.gpg``. When nothing verifies,
it refuses, changes nothing and exits 4:

.. code-block:: console

   # keel-transition --apply
   keel-transition: refusing --apply: there is no InRelease and no Release.gpg
     at https://archive.keellinux.org/dists/trixie: that archive is unsigned today
   keel-transition: an archive nothing signs would let whatever answers for that
     name install code as root here, so it is never enabled silently.
   keel-transition: nothing was changed. Re-run with --force-unsigned to accept
     that risk explicitly.

That is the expected answer today: the archive at
``archive.keellinux.org`` is empty and unsigned until the signing subkey
rotation of decision 0005 lands. The tool checks, it does not assume, so
the day the archive is signed the same command succeeds with no change
here.

``--force-unsigned`` overrides the refusal. It prints a warning naming
the risk and writes the source with ``Trusted: yes``, which turns apt's
signature checking off for that archive: anything that can answer for
that name, and any proxy on the way, can then install code that runs as
root on the appliance. Test benches only.

IPv6
====

Every fetch is ``curl --ipv6``: the archive is reached over IPv6 or not
at all (BRIEF section 10). A staging archive on a build host, by address:

.. code-block:: console

   # keel-transition --apply --force-unsigned \
       --archive-uri 'http://[2804:710:d0:5:bb3f:380a:f07b:7951]:8081' \
       --suite trixie-staging
   # apt-get update
   # apt-cache policy keel
   keel:
     Installed: (none)
     Candidate: 0.1.0
     Version table:
        0.1.0 990
          990 http://[2804:710:d0:5:bb3f:380a:f07b:7951]:8081 trixie-staging/main amd64 Packages

Note the 990: the pin is what makes the project's package win, and it
never wins over a newer version already installed.

Exit codes
==========

===  ============================================================
  0  Success, including every no-op case
  1  Usage error
  2  ``--apply`` or ``--rollback`` on the live system, not as root
  3  ``keel inspect`` could not infer a required field
  4  The archive has no Release that the keyring verifies
  5  A file could not be written, or one at our path is not ours
  6  ``keel-archive-keyring`` is not installed
  7  ``--rollback`` left something behind, and said what
  8  The ``keel`` command is not installed
===  ============================================================

Installing
==========

.. code-block:: console

   # apt-get install keel-archive-keyring keel-transition

Until the archive is signed and published, build the two packages from
this tree:

.. code-block:: console

   $ dpkg-buildpackage -us -uc -b
   # dpkg -i ../keel-archive-keyring_0.1.0_all.deb ../keel-transition_0.1.0_all.deb

or, on the build host, with the apt tooling, which detects this as a
native package because its source name starts with ``keel`` and it
records no upstream:

.. code-block:: console

   $ ssh root@2804:710:d0:5:bb3f:380a:f07b:7951 \
       'TERM=dumb /srv/keel-apt/apt/bin/build-package keel-transition' | cat

Running from a checkout
=======================

The executable looks for its library in ``/usr/lib/keel-transition``.
Point it elsewhere to run it from this tree:

.. code-block:: console

   $ KEEL_TRANSITION_LIB=$PWD/lib bin/keel-transition --help

Tests
=====

``tests/`` is a bats suite: every function, every branch and every exit
code, against a scratch ``/etc`` tree reached through ``--root``, with
PATH stubs for ``curl``, ``keel`` and ``id`` and throwaway OpenPGP keys
generated inside each test. Nothing touches the live system, needs root
or reaches the network.

.. code-block:: console

   $ bats tests/
   $ tests/coverage.sh

``tests/coverage.sh`` runs the same suite under kcov and fails below 95
percent per file (decisions 0003 and 0004);
``.github/workflows/tests.yml`` runs it through the organization's
``test-shell.yml``. See COVERAGE.md.

License
=======

GPL-3.0-or-later (decision 0007). See LICENSE.
