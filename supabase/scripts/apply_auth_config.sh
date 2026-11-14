#!/usr/bin/env bash
# Applies the Supabase Auth settings in supabase/auth-config.json to a project (Management API), file first like the migrations.
#   - sign-ups are OFF: nobody can create an account by signing in; staff are invited (dashboard: Authentication > Users > Invite);
#   - sign-in is by email link (magic link) and, when GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are given, by Google. Both only work for an invited address.
#   - APP_URL (optional) becomes the site address and the allowed redirect for the sign-in links.
# Needs SUPABASE_ACCESS_TOKEN and PROJECT_REF. Only the keys below are sent: nothing else in the project's auth settings is touched.
set -euo pipefail
: "${SUPABASE_ACCESS_TOKEN:?}" "${PROJECT_REF:?}"
here="$(cd "$(dirname "$0")/.." && pwd)"
api="https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth"

body="$(cat "$here/auth-config.json")"
if [ -n "${APP_URL:-}" ]; then
  body="$(jq --arg url "${APP_URL%/}" '. + {site_url: $url, uri_allow_list: ($url + "/**")}' <<<"$body")"
fi
if [ -n "${GOOGLE_CLIENT_ID:-}" ] && [ -n "${GOOGLE_CLIENT_SECRET:-}" ]; then
  body="$(jq --arg id "$GOOGLE_CLIENT_ID" --arg secret "$GOOGLE_CLIENT_SECRET" '. + {external_google_enabled: true, external_google_client_id: $id, external_google_secret: $secret}' <<<"$body")"
fi

curl -sS --fail-with-body -X PATCH "$api" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" -d "$body" >/dev/null
echo "Applied. Now on the project:"
now="$(curl -sS --fail-with-body "$api" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")"
jq '{disable_signup, external_email_enabled, mailer_autoconfirm, external_google_enabled, site_url, uri_allow_list}' <<<"$now"
test "$(jq -r .disable_signup <<<"$now")" = "true" || { echo "disable_signup is not true"; exit 1; }
