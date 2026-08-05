# Generate Oracle Static Role tfvars — RAC Cluster Discovery for Vault

> **Note for whoever pastes this in:** paste directly into the Confluence editor — headings, tables and code blocks convert cleanly. The Mermaid diagram needs a Mermaid macro/app to render; otherwise use it as a code block or pull the diagram from `generate_oracle_static_role_tfvars.README.md` in the repo.

## Summary

`generate_oracle_static_role_tfvars.yml` is an Ansible playbook that scans a flat list of Oracle ExaCC nodes — which may belong to any number of separate RAC clusters — and discovers, per cluster, which databases exist and which hosts they run on. It turns that into a Vault **static role** map (`username` + `connection_url` per database) that a downstream pipeline step consumes to render Terraform `tfvars` for Vault's Oracle DB secrets engine.

| | |
|---|---|
| **Repo path** | `generate_oracle_static_role_tfvars.yml` (single-file playbook, no supporting role directory) |
| **Owning team** | *(fill in — DPE / Oracle platform engineering)* |
| **Run via** | AWX/Ansible Controller job template, feeding a downstream Terraform apply step |
| **Depends on** | Hosts must already have Vault SSH OTP configured — see the `dpe_oracle_otp` playbook/page |

## What problem this solves

Vault's DB secrets engine needs a static role per (database, username) pair, each pointing at a `connection_url` of the hosts that database actually runs on. That topology:

- Isn't known ahead of time from a flat node list — the same node list can span many independent RAC clusters.
- Is expensive to query per-node (`srvctl` calls), so running it on every node in a large estate would be wasteful and slow.

This playbook solves both problems by fingerprinting cluster membership cheaply first, then running the real discovery only once per unique cluster.

## How it works

Five sequential plays:

1. **Build dynamic inventory** — validates the `exacc_node_list` extra-var, grabs a Vault login token, and loads every node into an in-memory group. No static inventory file needed.
2. **Fingerprint clusterware** — runs the lightweight, read-only `olsnodes` command on **every** node in parallel to learn each node's RAC peers. Nodes in the same cluster end up with an identical fingerprint. Unreachable nodes are skipped, not fatal.
3. **Select one representative per cluster** — dedupes by fingerprint, picking one node to represent each distinct cluster.
4. **Discover DB topology** — runs the heavier `srvctl` discovery *only* on representatives (one per cluster, safe to parallelise since each covers different infrastructure), building a database → hosts map and then the static-role map.
5. **Aggregate and publish** — merges every cluster's roles into one map and exposes it as a job artifact (`oracle_static_roles`) for the downstream Terraform step to consume.

Full task-by-task detail, all variables, and a Mermaid sequence diagram live in the repo: `generate_oracle_static_role_tfvars.README.md`.

## Inputs

**Required extra-var:**
- `exacc_node_list` — flat list of node FQDNs to scan, e.g. `-e '{"exacc_node_list": ["node1.example.com","node2.example.com"]}'`. Doesn't need to be pre-grouped by cluster.

**Required environment variables** (same as the OTP setup playbook): `_CLIENT__HASHI_URL`, `_CLIENT__HASHI_NAMESPACE`, `_CLIENT__HASHI_ROLE`.

**Optional extra-vars:**

| Variable | Default | Purpose |
|---|---|---|
| `grid_home` | `/u01/app/19.0.0.0/grid` | Grid Infrastructure home, provides `olsnodes`/`srvctl` on `PATH`. |
| `dns_domain` | `systems.uk._client_` | Suffix used to build FQDNs for `connection_url`. |
| `oracle_role_usernames` | `["sys"]` | DB usernames to generate a static role for, per database. |
| `role_suffix` | `"EXACC"` | Suffix on every generated role key. |
| `debug_output` | `false` | Dump per-cluster role maps to the job log. |

## Output

A single job artifact, `oracle_static_roles` — one entry per (database, role username) pair across **every** cluster found:

```json
{
  "SYS_ORCLDB1_EXACC": {
    "username": "SYS",
    "connection_url": "exacc-node01.systems.uk._client_,exacc-node02.systems.uk._client_"
  }
}
```

This is entirely read-only discovery — the playbook makes no changes on any target host.

## Running it

```
ansible-playbook generate_oracle_static_role_tfvars.yml \
  -e '{"exacc_node_list": ["exacc-node01.example.com","exacc-node02.example.com"]}'
```

Run via the AWX/Controller job template that feeds the downstream Terraform step, so the Vault environment variables and OTP-capable execution environment are already correct.

## Known gaps / things to check

- `dns_domain` defaults to `systems.uk._client_` in the code — confirm that's still the correct estate domain before relying on the default in a new environment; override explicitly if not.
- Representative selection is "first reachable node wins" per cluster fingerprint — there's no preference for a particular node (e.g. current SCAN listener owner). If a specific node needs to be favoured for discovery, that logic isn't present today.
- A node that's unreachable during fingerprinting (Play 2) is silently excluded rather than retried — if an entire cluster's nodes are all unreachable in one run, that cluster simply won't appear in the output with no hard failure. Worth confirming this silent-drop behaviour is acceptable for the downstream Terraform consumer (a cluster quietly disappearing from `tfvars` could remove a static role rather than just skip an update).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| A known cluster is missing from `oracle_static_roles` | All its nodes failed `olsnodes` (Play 2) — check OTP SSH setup / network reachability for that cluster's nodes. |
| `srvctl config database` step fails on a representative | Representative selection landed on a node where the Grid/DB stack isn't fully up — check `grid_home` and that `olsnodes` succeeded doesn't guarantee `srvctl` is fully healthy. |
| `connection_url` missing expected hosts | Check the regex assumption in Play 4 (`is running on node (\S+)`) still matches this Oracle version's `srvctl status database` output format. |
| Wrong domain in `connection_url` | Override `dns_domain` extra-var — don't rely on the in-code default for a new environment. |

## Related

- Repo README with full variable reference and sequence diagram: `generate_oracle_static_role_tfvars.README.md`
- OTP prerequisite playbook/page: `dpe_oracle_otp` (README: `dpe_oracle_otp/README.md`)
- *(Add links here to: the downstream Terraform job template that consumes `oracle_static_roles`, and the Vault DB secrets engine config it feeds.)*
