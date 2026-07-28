# Draft

**Nothing under a `draft/` directory is decided.** Not the designs, not the
ADRs, not the specs.

Some were reviewed, some reviewed many times. A passed review says the
reasoning holds together — it does not say the design was adopted. Some say
"implemented"; that describes code that exists, not a commitment to keep it.
Read every normative-sounding sentence here as *"if this were adopted, it
would work like this."*

Do not implement from a document under `draft/`. Do not cite one as the reason
something is the way it is. Do not build a runbook or a README step from one.

The rule that puts a document here is simple: **it has not been published on
`main`.** Anything outside `draft/` is on `main` and is a commitment to users.

## Why this exists

A design here recorded that the shipped onboarding creates a team in the
opposite order from the intended one, and named the schema constraints causing
it. Work continued against the shipped order for two days — nobody treated the
document as a gate, because a status line inside a file is connected to
nothing, and neighbouring files described working code. A separate runbook was
then written teaching a command that the same directory said should not exist.

Splitting by directory makes the distinction visible from the path, before the
file is opened.

## Leaving draft

A draft leaves in one of two ways: it becomes true of the code and is published
to `main`, or it is abandoned and deleted. Editing a draft until it reads as
authoritative is neither.
