#!/usr/bin/env bash
#
# Prepare the RDS database for the Agent Server.
#
# The only mandatory step is creating the `vector` extension: langgraph.json pins the
# store index to huggingface:microsoft/harrier-oss-v1-270m at 640 dimensions, and the
# current stack runs pgvector/pgvector:pg16 for exactly this reason. Without the
# extension, every store write fails at runtime rather than at deploy time.
#
#   ./scripts/bootstrap-db.sh                    # create the extension and verify
#   ./scripts/bootstrap-db.sh --restore dump.pgc # then restore a pg_dump -Fc archive
#
# Connectivity: RDS is in private subnets. Run this from inside the VPC, or open a port
# forward first:
#
#   aws ssm start-session --target <bastion-instance-id> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["5432"]}'
#
# and then set DATABASE_URI to point at localhost:5432.

set -euo pipefail

TERRAFORM_DIR="${TERRAFORM_DIR:-terraform/envs/prod}"
restore_archive=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --restore) restore_archive="$2"; shift 2 ;;
        --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v psql >/dev/null || { echo "psql not found (install the postgresql client)." >&2; exit 1; }

# Prefer an explicitly exported URI; otherwise read it from Terraform state.
if [[ -z ${DATABASE_URI:-} ]]; then
    command -v terraform >/dev/null || {
        echo "DATABASE_URI is not set and terraform is unavailable to read it." >&2
        exit 1
    }
    echo "==> Reading the connection URI from ${TERRAFORM_DIR}"
    DATABASE_URI="$(terraform -chdir="$TERRAFORM_DIR" output -raw rds_connection_uri)"
fi
export DATABASE_URI

# Never echo the URI itself: it carries the master password.
echo "==> Target: $(printf '%s' "$DATABASE_URI" | sed -E 's#//[^@]*@#//***@#')"

echo "==> Creating the pgvector extension if it is missing"
psql "$DATABASE_URI" --set ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL

echo "==> Verifying"
installed_version="$(psql "$DATABASE_URI" -tAc \
    "SELECT extversion FROM pg_extension WHERE extname = 'vector';")"

if [[ -z $installed_version ]]; then
    echo "FAILED: the vector extension is not installed. The Agent Server's store will not work." >&2
    exit 1
fi
echo "    pgvector ${installed_version} is installed."

server_version="$(psql "$DATABASE_URI" -tAc 'SHOW server_version;')"
echo "    PostgreSQL ${server_version}"

# A restore into a mismatched major version is not a valid operation, and the failure
# mode is confusing enough to be worth catching up front.
if [[ -n $restore_archive ]]; then
    case "$server_version" in
        16.*) ;;
        *)
            echo "WARNING: the source dump came from PostgreSQL 16 (pgvector/pgvector:pg16)," >&2
            echo "         but this server reports ${server_version}. Verify before restoring." >&2
            ;;
    esac

    [[ -f $restore_archive ]] || { echo "Archive not found: ${restore_archive}" >&2; exit 1; }
    command -v pg_restore >/dev/null || { echo "pg_restore not found." >&2; exit 1; }

    echo "==> Restoring ${restore_archive}"
    echo "    Take the dump with the API stopped, or writes made after it are lost."
    pg_restore --no-owner --no-privileges --dbname "$DATABASE_URI" "$restore_archive"
    echo "    Restore complete."
fi

echo
echo "==> Database ready. Next: docs/runbook.md §1.4 (push images)."
