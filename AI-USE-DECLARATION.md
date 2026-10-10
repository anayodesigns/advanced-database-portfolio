# AI Use Declaration

*Required by section 11 of the assessment brief. Sections 1 and 2 describe what the AI tool actually did. **Section 3 must be completed by the student** in their own words, describing only what they actually did.*

## 1. AI tool used

**Claude (Anthropic), model Claude Opus 5.5**, used through **Claude Code** (the Claude desktop app's coding agent). The agent can run commands on the student's computer.

## 2. What the AI tool was used for

The AI tool did a large share of the technical work in this repository:

- **Environment:** installed portable PostgreSQL 17.6 and MongoDB 8.0.4 binaries without admin rights, and wrote the start/stop scripts.
- **Portfolio 1:** proposed the SwiftMove case study (the student asked the AI to choose); designed the schema, constraints and ER diagram; wrote the deterministic data generator and integrity checks; drafted the normalisation write-up.
- **Portfolio 2:** wrote the eight queries, the before/after runner, the indexes and materialized view, and experiments E1–E7; ran them and drafted the performance analysis.
- **Portfolio 3:** wrote `pay_trip()`, the two-session test harness, demos 01–08 and the pgbench stress test; ran them and drafted the analysis.
- **Portfolio 4:** wrote the PostgreSQL → MongoDB export, the validated document model, the demos (indexes, geospatial, TTL, graph) and the analysis.
- **Portfolio 5:** wrote and ran the replication, failover, replica-set, sharding and partitioning scripts; wrote the cloud deployment design.
- **Documentation:** drafted every README file and this declaration's sections 1 and 2.

**How the AI checked its own work.** Every result in the READMEs comes from scripts actually executed on the student's machine; the outputs are committed as evidence. While working, the AI found and fixed several of its own mistakes. These are recorded in the READMEs:
- a seed-data ID collision
- functions missing a pinned `search_path`
- an invalid first benchmark design
- a hung polling loop
- a MongoDB zone boundary that broke targeted routing
- TTL and validation demos that initially proved the wrong thing

Figures from earlier runs are labelled as such.

**What the AI did *not* do:**
- write the individual technical reflection
- fabricate outputs or screenshots
- alter commit timestamps

Each commit made by the AI carries a `Co-Authored-By: Claude` trailer.

## 3. How the output was reviewed, corrected, tested or verified by the student

> **To be completed by the student, truthfully.** Only list what you actually did. For example:
> - which scripts you re-ran yourself, and whether your results matched the committed evidence
> - which parts you read line by line and could explain in a verification discussion
>   (e.g. the normalisation steps, why Q4 needs a materialized view, why REPEATABLE READ does not stop write skew, why `city = "Lagos"` hit two shards before the zone fix)
> - anything you changed, corrected or rejected
> - concepts you looked up in the course material or references to confirm the AI's explanations

_…student's text here…_

---
Student name: ______________________  Signature/Date: ______________________
