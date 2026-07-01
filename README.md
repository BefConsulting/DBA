# Ops Handbook

A personal reference for operations and platform engineering: notes, study guides, and runnable artifacts across databases, infrastructure-as-code, configuration management, and CI/CD.

Each section follows the same pattern: a `docs/` folder for concepts and best practices, plus folders holding runnable artifacts (scripts, modules, playbooks, pipelines).

## Sections

| Section | Focus | Contents |
|---------|-------|----------|
| [databases/](databases/) | PostgreSQL administration & reliability | `docs/` guides, `lab/` EXPLAIN lab, `scripts/` monitoring SQL |
| [terraform/](terraform/) | Infrastructure as Code | `docs/`, reusable `modules/` |
| [ansible/](ansible/) | Configuration management | `docs/`, `playbooks/` |
| [jenkins/](jenkins/) | CI/CD pipelines | `docs/`, `pipelines/` |

## Layout

```
ops-handbook/
├── README.md
├── databases/
│   ├── README.md
│   ├── docs/         # internals, performance, WAL, HA/DR, Patroni
│   ├── lab/          # EXPLAIN practice DB + scenarios
│   └── scripts/      # ready-to-run monitoring SQL
├── terraform/
│   ├── docs/
│   └── modules/
├── ansible/
│   ├── docs/
│   └── playbooks/
└── jenkins/
    ├── docs/
    └── pipelines/
```

## Status

| Section | State |
|---------|-------|
| databases | Populated — guides, lab, and monitoring scripts |
| terraform | Scaffolded — ready for content |
| ansible | Scaffolded — ready for content |
| jenkins | Scaffolded — ready for content |

Start with [databases/README.md](databases/README.md).

## Interview prep

- [dbre.md](dbre.md) — technical study guide for the PostgreSQL DBRE/SRE role (SLOs/error budgets, Datadog, HIPAA, Azure/K8s, RepMgr/HAProxy/PgBouncer/PgBackRest, ITSM, ETL) with a time-boxed game plan and questions to ask back.
- [star-stories.md](star-stories.md) — manager/behavioral round: the STAR method, five elaborated stories, questions to ask, and logistics.
