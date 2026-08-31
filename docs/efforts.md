# Compliance efforts

One Compliance Claw deployment can serve several **efforts**. An effort is one
**system + one framework**, with its own review targets and its own Pretorin
credential.

That pairing is not a convention this repository invented. Pretorin keys
preflight state and the active recipe set on system + framework, so the same
system under SOC 2 and under HIPAA is **two separate compliance efforts** with
two separate sets of bound repositories and two separate recipe sets. `efforts.yaml`
declares them; `scripts/clawctl` validates, migrates and applies them.

> **Status.** `targets.yaml` is still what the running deployment reads. This
> release adds the format, the control command and the credential mechanism, and
> proves them. A later release makes `efforts.yaml` authoritative and generates
> one agent and one Slack channel per effort.

---

## The main event: adding a second effort

This is the case the whole format exists for — the same repositories, reviewed
under a second framework.

### 1. Declare it

Open `efforts.yaml` and copy the block you already have, changing the framework
and the name:

```yaml
efforts:
  - name: crm-soc2
    system_id: 13c1f44e-b66d-417c-8604-4ac7b988b411
    framework_id: soc2
    credential_ref: default
    targets:
      - name: simple-crm
        url: https://github.com/pretorin-ai/simple-crm.git
        ref: main
    connections: []

  - name: crm-hipaa                                  # NEW
    system_id: 13c1f44e-b66d-417c-8604-4ac7b988b411  # the same system
    framework_id: hipaa                              # a different framework
    credential_ref: hipaa-key                        # its own credential
    targets:
      - name: simple-crm                             # the SAME repository
        url: https://github.com/pretorin-ai/simple-crm.git
        ref: main
    connections: []
```

`simple-crm` appears in both, and that is intended. Target names are a **global
namespace**: every target is cloned once to `workspace/targets/<name>`, and
Pretorin derives resolver names from the directory basename. One clone gets bound
into both scopes.

The same name in two efforts is allowed **only when the definitions are
identical**. Two different `url`s, `ref`s or `private` flags under one name is
refused, naming both efforts and the field that differs — otherwise whichever
effort synchronised last would silently decide what the other one is reviewing.

### 2. Create its credential

```sh
scripts/clawctl credential add hipaa-key
```

Then paste the Pretorin API key into the file it names. The command never reads
or prints a value.

**Use this command rather than creating the file by hand.** Compose file secrets
are bind mounts and cannot remap uid or mode. The container runs as uid 1000; you
almost certainly do not. A hand-made `chmod 600` file is therefore **unreadable
inside the container**, and the symptom is a Pretorin *authentication* error —
sending you to the platform to check a key that is perfectly fine. `credential add`
applies the same mode logic `scripts/init-file-secrets.sh` already uses, and
`clawctl validate` names a wrong-mode file explicitly rather than letting it
surface as a fake auth failure.

### 3. Check it

```sh
scripts/clawctl validate
```

```
  EFFORT                 SCHEMA  CREDENTIAL  MODE    PROBE
  ---------------------- ------- ----------- ------- -----
  crm-soc2               ok      ok          ok      ok
  crm-hipaa              ok      ok          ok      ok
```

`validate` checks **every** effort in one run rather than stopping at the first
problem, so configuring three efforts does not mean three edit-run cycles. Within
a row it short-circuits — schema, then the file, then the mode, then the probe —
because probing a credential the container cannot read produces a misleading
error.

The probe runs through the real chain: the mounted credential directory, the
launcher, the credential ladder, the scope pin, and a scoped platform read.

### 4. Preview, then apply

```sh
scripts/clawctl plan      # prints the exact commands; starts NO containers
scripts/clawctl apply     # sweep -> bind -> verify -> provision -> assert, per effort
```

`plan` and `apply` cannot drift: both render each command from the same data, so
a printed line **is** the command, shell-quoted so you can paste it back.

---

## Credentials

### `credential_ref` is a name, never a token

`efforts.yaml` holds no secret and is safe to commit. Values live in files:

| `credential_ref` | host file | in the container |
| --- | --- | --- |
| `default` | `secrets/runtime/pretorin-api-key` | `/run/secrets/pretorin_api_key` |
| `<name>` | `secrets/runtime/pretorin/<name>` | `/run/compliance-claw/credentials/<name>` |

`default` is **reserved**. It names the credential a single-effort deployment
already had, so migrating needs no new secret file at all. A file literally named
`secrets/runtime/pretorin/default` would shadow it with no way to tell which one a
process read, so it is refused.

### One key or many

**One org-wide key** is less to rotate and lets every effort reach every system;
**one key per system** limits the blast radius of a leak and is the only thing
that stops one effort's agent from *reading* another system's data. Both are
first-class — point several efforts at one `credential_ref`, or give each its own.

### What you choose when you mint the token

**In Pretorin, not here.** Every one of these is your decision at mint time, and
Compliance Claw neither sets, inspects, nor reports any of them:

- **Read or write.** A read-only key is enough for onboarding and for review. A
  write-enabled key is what lets an agent create risks, evidence and narratives.
- **One system or all systems.** The narrower the key, the less an effort can
  reach — including by accident.
- **Extra capabilities**, such as connected-source administration. Grant them only
  to the effort that needs them.
- **Expiration and rotation.** Set an expiry, and decide the rotation cadence.
  Rotation here is: paste a new value into the same file, then
  `docker compose restart openclaw`.

### The authorization boundary is the key, and only the key

**Compliance Claw enforces nothing locally.** There is no read-only mode, no
permission setting, and no tool allowlist standing between an agent and Pretorin.
What a key can do is decided server-side by that key's own scopes. Anything this
repository appears to "allow" is a cost or context control, never an
authorization one.

Two consequences worth stating plainly:

**Writes are scope-guarded; reads are not.** With an MCP process pinned to effort
A, a *write* aimed at another system or framework is refused by Pretorin, and a
caller-supplied `allow_scope_override` is ignored. A *read* is not constrained by
the pin: it is governed by its own arguments and by what the key can see. So an
agent pinned to one effort **can read another system's data if its key has access
to that system**. If read isolation between efforts matters to you, that is an
argument for per-system keys, not for a setting here. Measured against CLI
0.28.7; the evidence is in [plans/effort-config.md](plans/effort-config.md).

**Tool execution is unsandboxed.** The credential files are readable by the
container user, and so is anything else that user can reach. See `SECURITY.md`.

---

## Migrating from `targets.yaml`

```sh
scripts/clawctl migrate --name crm-soc2
scripts/clawctl validate
scripts/clawctl plan
scripts/clawctl apply
```

**What is preserved.** `targets.yaml` is **not modified** and is still what the
running deployment reads. Every target carries over verbatim — name, url, ref and
the `private` flag. The scope becomes effort #1, and its `credential_ref` is
`default`, so **no secret is copied and no new file is created**.

**Why `--name` is required when your `system_id` is a UUID.** The effort name
becomes an agent identity and a Slack channel name in a later release, where a
UUID is permanent and unreadable. `migrate` refuses to generate one rather than
leave you with `13c1f44e-…-soc2` in a channel list.

**It runs once.** A second `migrate` refuses cleanly rather than overwriting your
edits, the same write-if-absent rule the rest of this deployment follows.

**What `down -v` would cost.** It deletes **both** named volumes: the OpenClaw
state volume (config, sessions, agent workspace, custom `AGENTS.md`) **and** the
Pretorin state volume (active context, preflight resolvers, active recipe sets
for every effort, and the `clawctl` audit record). It does not touch
`workspace/targets`. Recovery is `scripts/bootstrap.sh` then
`scripts/clawctl apply`; both are idempotent.

---

## Two things `apply` does that are worth knowing

**It takes a lock, and it is the lock that already exists.** `apply` mutates the
Pretorin state volume, and so does `scripts/pretorin-update.sh`, which replaces
the active CLI binary. Both now coordinate on the same `flock`, so an update
cannot swap the binary out from under a running sequence and two `apply` runs
cannot interleave. If it is held, `apply` refuses and names the two things it
could be — `flock` records no holder identity, so it does not pretend to know.

**It writes an audit record.** One line per effort per run, appended in the state
volume and echoed to the container logs: timestamp, effort, system, framework,
credential **name**, targets bound, outcome. It never contains a credential value.
This is the same convention as the target-sync and CLI-update records.

---

## Known limitations in this release

**Effort-aware cloning is not wired yet.** `scripts/bootstrap.sh` still clones
from `targets.yaml`. A migrated effort and any effort sharing its repositories are
already cloned and work today; a genuinely new repository must be added to
`targets.yaml` and cloned there for now. `apply` refuses rather than binding a
path that is not present, and says so.

**Slack RBAC is channel-level, not user-level.** Every member of a shared channel
can address the agent, and the agent acts with the deployment's credential — not
with the requesting user's permissions. There is no per-user authorization in the
pilot. Keep an effort's channel membership to the people who should be able to act
in that compliance scope.

**`connections:` is reserved and inert.** It is validated as present-but-empty and
consumed by nothing. It is the future home of Pretorin **Connected Sources** —
Azure and AWS — which is how the capabilities a local workspace cannot satisfy
(branch protection, pull-request records, code-review records) get supplied.
Declaring the shape now means it is fixed before it carries meaning; putting
anything under it is refused today, on purpose.
