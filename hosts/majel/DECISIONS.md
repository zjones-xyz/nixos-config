# majel — decision log

The Home Assistant host: a Lenovo IdeaCentre 310S replacing the Raspberry Pi 5.
Each entry: **decision → alternatives → rationale.**

**Documentation only.** There is no `configuration.nix` yet. `PLAN.md` is the
onboarding plan, and its §9 lists the decisions still open. Each one gets an
entry here once it is made.

Dates are UTC.

---

## 1. The name

**`majel`** (2026-11-09). *Alternatives:* `zora`, `holly`, `mother`, `edi`,
`wiener`, `tardis`, `rocinante`, `lcars`, `zen`, `orac`, `eddie`, `gideon`,
`munin`, `hugin`, `falken`, `morgan`, `nemo`.

*Why `majel`:* Majel Barrett voiced the Starfleet computer for decades. Hers is
the voice that answered "Computer, lights", which is this host's whole job. It
also ties to the fleet's existing Star Trek name, memory-alpha, the way pegasus
and galactica pair up from Battlestar Galactica.

*Rejected along the way:*

- **Ace Combat's `zoe`.** It is the owner's own name, which makes
  `ssh zoe@zoe` ambiguous.
- **`dision`.** It is named after the Ace Combat 3 antagonist who wanted to
  upload everyone into the Electrosphere. Not a namesake for the box that runs
  the house.
- **Battlestar Galactica and Firefly** have no ship's AI to borrow from.
  Galactica survived because its computers were *not* networked.
