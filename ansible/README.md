# Ansible

Configuration-management notes and playbooks.

## Layout

| Path | Purpose |
|------|---------|
| `docs/` | Concepts, inventory, roles, best practices |
| `playbooks/` | Runnable playbooks and roles |

## Suggested topics for `docs/`

- Inventory (static vs dynamic), groups, `group_vars` / `host_vars`
- Playbook structure, tasks, handlers, idempotency
- Roles and `ansible-galaxy` layout
- Secrets with Ansible Vault
- Templating with Jinja2, facts, conditionals/loops
- Common patterns: rolling restarts, package/service management, DB provisioning — see [../databases/](../databases/)

---

**See also:** [../README.md](../README.md)
