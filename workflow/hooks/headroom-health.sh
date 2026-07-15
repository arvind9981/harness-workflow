#!/usr/bin/env bash
# SessionStart(startup|resume): report-only liveness probe for the headroom proxy.
# ANTHROPIC_BASE_URL routes every request through 127.0.0.1:8787 with no fallback, so
# if the proxy is down the session fails with ConnectionRefused on the first API call
# and no hint why. This surfaces a user-visible systemMessage (additionalContext is
# useless when the proxy — and thus the model — is unreachable). Report-only: it does
# NOT restart anything (auto-restart would mask a crashloop). Healthy -> silent, exit 0.
URL="${HEADROOM_HEALTH_URL:-http://127.0.0.1:8787/health}"

command -v curl >/dev/null 2>&1 || exit 0            # can't probe -> don't cry wolf
curl -fsS --max-time 2 "$URL" >/dev/null 2>&1 && exit 0   # healthy -> stay silent
command -v jq >/dev/null 2>&1 || exit 0              # can't format the message -> quiet

if [ "$(uname -s)" = "Darwin" ]; then
  fix="launchctl kickstart -k gui/$(id -u)/com.user.headroom-proxy  (or: headroom proxy --port 8787 --host 127.0.0.1)"
else
  fix="systemctl --user restart headroom-proxy  (check: systemctl --user status headroom-proxy; keep it up across logout: loginctl enable-linger $USER)"
fi
msg="⚠️  headroom proxy not responding at ${URL} — this agent's proxied API calls will fail with ConnectionRefused. Start it: ${fix}"

jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m},systemMessage:$m}'
exit 0
