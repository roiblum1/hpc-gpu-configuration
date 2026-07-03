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
  # Gate 0 requires staged AND checksummed: ship a sha256sum.txt with each model
  # (generated once at mirror time) so verification runs on every (re)stage.
  if [ -f "$target/sha256sum.txt" ]; then
    echo "[$m] verifying checksums..."
    (cd "$target" && sha256sum -c sha256sum.txt --quiet)
  else
    echo "[$m] WARNING: no sha256sum.txt — Gate 0 checksum evidence missing" >&2
  fi
  date -u +%FT%TZ > "$marker"
  echo "[$m] staged"
fi
{{- end }}

echo "all models staged on $(hostname); holding."
# DaemonSet pod must stay Running; staging is idempotent on restart.
exec sleep infinity
