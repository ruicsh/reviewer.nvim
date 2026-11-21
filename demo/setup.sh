#!/usr/bin/env bash
# Build the throwaway repository the demo GIF records against.
#
#   demo/work/acme-api   a small TypeScript service on feature/retries:
#                        src/api.ts modified in the working tree, src/db.ts
#                        staged with a retry loop.
#
# Re-running resets the repo and drops any review comments recorded against it,
# so the recording always starts from the same state. Generated, gitignored.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$here/work/acme-api"

# reviewer.nvim keys its store by a hash of the repository root plus the branch.
# Same formula as lua/reviewer/store.lua, so the demo starts with no comments.
store="$HOME/.local/share/nvim/reviewer"
if [ -d "$store" ]; then
  key="$(
    python3 - "$repo" <<'PY'
import sys
h = 0
for b in sys.argv[1].encode():
    h = (h * 31 + b) % 2147483647
print(format(h, "x"))
PY
  )"
  rm -f "$store/$key-feature_retries.json"
fi

rm -rf "$repo"
mkdir -p "$repo/src"
cd "$repo"

git init -q -b main
git config user.email "dev@acme.test"
git config user.name "Dev"

cat > src/api.ts <<'EOF'
import { fetchJson } from "./http";
import type { Order, User } from "./types";

const BASE_URL = "https://api.acme.dev/v1";

export async function getUser(id: string): Promise<User> {
  const res = await fetch(`${BASE_URL}/users/${id}`);
  const data = await res.json();
  return data;
}

export async function listOrders(userId: string): Promise<Order[]> {
  const res = await fetch(`${BASE_URL}/orders?user=${userId}`);
  const data = await res.json();
  return data.orders;
}
EOF

cat > src/db.ts <<'EOF'
import { pool } from "./pool";

type Row = Record<string, unknown>;

export async function query(sql: string, params: unknown[] = []): Promise<Row[]> {
  const res = await pool.query(sql, params);
  return res.rows;
}
EOF

cat > src/http.ts <<'EOF'
export async function fetchJson(url: string) {
  const res = await fetch(url);
  return res.json();
}
EOF

cat > package.json <<'EOF'
{
  "name": "acme-api",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test"
  }
}
EOF

git add -A
git commit -qm "feat: add the orders endpoints"

# The review is on this branch: staged retry loop, unstaged endpoint changes.
git checkout -q -b feature/retries

cat > src/db.ts <<'EOF'
import { pool } from "./pool";

type Row = Record<string, unknown>;

const ATTEMPTS = 3;
const BACKOFF_MS = 50;

export async function query(sql: string, params: unknown[] = []): Promise<Row[]> {
  let lastError: unknown;
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    try {
      const res = await pool.query(sql, params);
      return res.rows;
    } catch (err) {
      lastError = err;
      await sleep(BACKOFF_MS * 2 ** attempt);
    }
  }
  throw lastError;
}
EOF

git add src/db.ts

cat > src/api.ts <<'EOF'
import { fetchJson } from "./http";
import type { Order, User } from "./types";

const BASE_URL = "https://api.acme.dev/v1";

export async function getUser(id: string): Promise<User> {
  const res = await fetch(`${BASE_URL}/users/${id}`);
  const data = await res.json();
  return data;
}

export async function listOrders(userId: string, status?: string): Promise<Order[]> {
  const query = status ? `?user=${userId}&status=${status}` : `?user=${userId}`;
  const res = await fetch(`${BASE_URL}/orders${query}`);
  const data = await res.json();
  return data.orders;
}

export async function cancelOrder(orderId: string): Promise<void> {
  const res = await fetch(`${BASE_URL}/orders/${orderId}`, { method: "DELETE" });
  if (!res.ok) {
    throw new Error(`cancel failed: ${res.status}`);
  }
}
EOF

echo "demo repo ready: $repo"
