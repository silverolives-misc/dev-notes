python3 - <<'PY'
import yaml, sys

with open("alert-rules.yml") as f:
    data = yaml.safe_load(f)

groups = data.get("groups", [])
for i, group in enumerate(groups):
    name = group.get("name")
    if not name:
        print(f"ERROR: group index {i} has empty name: {group}")
        sys.exit(1)

print("OK: all rule groups have names")
PY
