# Source this file: `. scripts/env.sh`
# Portable PostgreSQL 17 (EDB binaries) and MongoDB 8 installed under ~/.local/opt
# (no Homebrew or admin rights needed). Data directories live under ~/.local/var.
export OPT="$HOME/.local/opt"
export VAR="$HOME/.local/var"
export PATH="$OPT/pgsql/bin:$OPT/mongodb/bin:$OPT/mongosh-2.3.8-darwin-arm64/bin:$PATH"
export PGUSER=postgres
export PGHOST=localhost
export PGPORT=5433          # primary
export PGDATABASE=swiftmove
export REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
