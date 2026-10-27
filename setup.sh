#!/usr/bin/env bash
set -Eeuo pipefail

# Find repository directory and bench root directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$REPO_DIR/../.." && pwd)"

# Verify bench environment
ENV_PY="$BENCH_DIR/env/bin/python"
PIP="$BENCH_DIR/env/bin/pip"
APPS_FILE="$BENCH_DIR/sites/apps.txt"
APPS_JSON="$BENCH_DIR/sites/apps.json"

if [[ ! -x "$ENV_PY" || ! -x "$PIP" ]]; then
    echo "❌ ERROR: Cannot find bench virtualenv at $BENCH_DIR/env"
    echo "Please ensure this repository is cloned inside a Frappe bench 'apps/' directory."
    exit 1
fi

mkdir -p "$BENCH_DIR/apps"
touch "$APPS_FILE"

echo "=========================================================="
echo "🚀 Frappe Monorepo App Registration"
echo "Repository : $REPO_DIR"
echo "Bench Dir  : $BENCH_DIR"
echo "=========================================================="

# Find all candidate app folders (both root and apps/* subfolders)
candidate_dirs=()
for dir in "$REPO_DIR"/* "$REPO_DIR"/apps/*; do
    [[ -d "$dir" ]] || continue
    dir_name="$(basename "$dir")"
    # Skip .git or non-app folders
    if [[ "$dir_name" =~ ^(\.git|apps|env|node_modules|logs|sites)$ ]]; then
        continue
    fi
    candidate_dirs+=("$dir")
done

registered_count=0

for APP_DIR in "${candidate_dirs[@]}"; do
    # Verify it has packaging info (pyproject.toml or setup.py)
    if [[ ! -f "$APP_DIR/pyproject.toml" && ! -f "$APP_DIR/setup.py" ]]; then
        continue
    fi

    # Determine app name
    APP_NAME=""
    if [[ -f "$APP_DIR/pyproject.toml" ]]; then
        APP_NAME="$(sed -nE 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$APP_DIR/pyproject.toml" | head -n1)"
    fi
    if [[ -z "$APP_NAME" && -f "$APP_DIR/setup.py" ]]; then
        APP_NAME="$(sed -nE "s/.*name[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" "$APP_DIR/setup.py" | head -n1)"
    fi
    if [[ -z "$APP_NAME" ]]; then
        APP_NAME="$(basename "$APP_DIR")"
    fi

    # Verify hooks.py exists
    if [[ ! -f "$APP_DIR/$APP_NAME/hooks.py" ]]; then
        continue
    fi

    echo ""
    echo "📦 Found App: $APP_NAME ($APP_DIR)"

    TARGET="$BENCH_DIR/apps/$APP_NAME"

    # 1. Symlink to bench/apps/
    if [[ -L "$TARGET" ]]; then
        current_target="$(readlink -f "$TARGET")"
        expected_target="$(readlink -f "$APP_DIR")"
        if [[ "$current_target" != "$expected_target" ]]; then
            echo "   ⚠️  Updating symlink $TARGET -> $APP_DIR"
            rm -f "$TARGET"
            ln -s "$APP_DIR" "$TARGET"
        else
            echo "   ✓ Symlink already points to $APP_DIR"
        fi
    elif [[ -e "$TARGET" ]]; then
        if [[ "$(readlink -f "$TARGET")" == "$(readlink -f "$APP_DIR")" ]]; then
            echo "   ✓ Target directory matches $APP_DIR"
        else
            echo "   ❌ ERROR: $TARGET already exists and is not a symlink to $APP_DIR"
            continue
        fi
    else
        echo "   🔗 Creating symlink: $TARGET -> $APP_DIR"
        ln -s "$APP_DIR" "$TARGET"
    fi

    # 2. Pip install in editable mode
    echo "   ⚙️  Installing Python package in editable mode (-e)..."
    "$PIP" install --no-deps -e "$APP_DIR" > /dev/null

    # 3. Register in sites/apps.txt
    if ! grep -Fxq "$APP_NAME" "$APPS_FILE"; then
        echo "   📝 Adding to $APPS_FILE"
        printf '%s\n' "$APP_NAME" >> "$APPS_FILE"
    else
        echo "   ✓ Already in $APPS_FILE"
    fi

    # 4. Register in sites/apps.json (if apps.json exists)
    if [[ -f "$APPS_JSON" ]]; then
        "$ENV_PY" - << PYEOF
import json, subprocess

apps_json_path = "$APPS_JSON"
repo_dir = "$REPO_DIR"
app_name = "$APP_NAME"

try:
    with open(apps_json_path, "r") as f:
        data = json.load(f)
except Exception:
    data = {}

commit_hash = None
branch = None
try:
    commit_hash = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo_dir).decode().strip()
    branch = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo_dir).decode().strip()
except Exception:
    pass

if app_name not in data:
    data[app_name] = {
        "is_repo": True,
        "resolution": {
            "commit_hash": commit_hash,
            "branch": branch
        },
        "required": [],
        "idx": len(data) + 1,
        "version": "0.0.1"
    }
    with open(apps_json_path, "w") as f:
        json.dump(data, f, indent=4)
PYEOF
        echo "   📋 Registered in $APPS_JSON"
    fi

    registered_count=$((registered_count + 1))
done

# Setup Git Hooks for automatic sync on git pull and git checkout
GIT_HOOK_DIR="$REPO_DIR/.git/hooks"
if [[ -d "$GIT_HOOK_DIR" ]]; then
    for HOOK_NAME in post-merge post-checkout; do
        HOOK_FILE="$GIT_HOOK_DIR/$HOOK_NAME"
        cat << 'EOF' > "$HOOK_FILE"
#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "$REPO_DIR/setup.sh" ]]; then
    echo "🔄 Running setup.sh..."
    bash "$REPO_DIR/setup.sh"
fi
EOF
        chmod +x "$HOOK_FILE"
    done
fi

echo ""
echo "=========================================================="
echo "✅ Completed! $registered_count app(s) registered successfully."
echo "=========================================================="
echo "Next step (install to your site):"
echo "  bench --site <your-site> install-app <app-name>"
