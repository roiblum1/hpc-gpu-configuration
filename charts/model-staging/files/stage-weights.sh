#!/usr/bin/env bash
# Idempotent per-node weight staging — Phase 0. Templated by Helm (model-staging values).
# Stages each model to {{ .Values.hostPath }}/<name>, writes a .staged marker so pod
# restarts re-verify instead of re-copying. Worker pods mount the dir read-only.
set -euo pipefail

DEST="{{ .Values.hostPath }}"
mkdir -p "$DEST"

{{- range .Values.models }}
m="{{ .name }}"
target="$DEST/$m"
marker="$target/.staged"
if [ -f "$marker" ]; then
  echo "[$m] already staged at $(cat "$marker") — skipping"
else
  echo "[$m] staging..."
  mkdir -p "$target"
  {{- if eq $.Values.source.type "oci" }}
  skopeo copy --all "docker://{{ $.Values.source.registry }}/{{ .ref }}" "dir:$target"
  {{- else }}
  rsync -a --info=progress2 "{{ $.Values.source.rsyncBase }}/{{ .name }}/" "$target/"
  {{- end }}
  date -u +%FT%TZ > "$marker"
  echo "[$m] staged"
fi
{{- end }}

echo "all models staged on $(hostname); holding."
# DaemonSet pod must stay Running; staging is idempotent on restart.
exec sleep infinity
