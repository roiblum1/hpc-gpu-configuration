{{/* Comma-joined rail NAD annotation value. Entries are user-provided IB NAD names,
     rendered verbatim (prefix "<ns>/" in values if they live outside .namespace). */}}
{{- define "minimax.railAnnotation" -}}
{{- join "," .Values.rails.nads -}}
{{- end -}}

{{/*
Low-latency pod contract (§3.3 / §10): pairs with runtimeClassName (values
runtimeClassName) on GPU workers. irq-load-balancing steers device IRQs off the
pod's exclusive cores; cpu-quota removes CFS throttling from the hot loop.
*/}}
{{- define "minimax.lowLatencyAnnotations" -}}
irq-load-balancing.crio.io: "disable"
cpu-quota.crio.io: "disable"
{{- end -}}

{{/*
IB fabric + engine env, per design §3. Deliberately NO NCCL_IB_TC / GID index (RoCE
QoS knobs — IB QoS is the fabric's job) and NO UCX/NIXL vars (no disaggregation).
NCCL_IB_HCA lists compute rails ONLY; storage/mgmt HCAs must stay off this list.
Rendered as DynamoGraphDeployment envs[] entries. Call with root context.
*/}}
{{- define "minimax.fabricEnv" -}}
- {name: HF_HUB_OFFLINE, value: "1"}
- {name: VLLM_ALL2ALL_BACKEND, value: "{{ .Values.fabric.all2allBackend }}"}
- {name: VLLM_USE_DEEP_GEMM, value: "{{ .Values.fabric.useDeepGemm }}"}
- {name: NCCL_IB_HCA, value: "{{ .Values.fabric.ncclIbHca }}"}
- {name: NCCL_SOCKET_IFNAME, value: "{{ .Values.fabric.socketIfname }}"}
- {name: GLOO_SOCKET_IFNAME, value: "{{ .Values.fabric.socketIfname }}"}
- {name: NCCL_IB_TIMEOUT, value: "{{ .Values.fabric.ncclIbTimeout }}"}
- {name: NCCL_IB_RETRY_CNT, value: "{{ .Values.fabric.ncclIbRetryCnt }}"}
- {name: NCCL_IB_QPS_PER_CONNECTION, value: "{{ .Values.fabric.ncclIbQpsPerConnection }}"}
- {name: NCCL_CROSS_NIC, value: "0"}
{{- end -}}

{{/*
speculative-config JSON: dflash (default — draft staged at modelPaths.dflashDraft)
or the zero-artifact mtp fallback (native heads in the checkpoint). design §6.
*/}}
{{- define "minimax.speculativeConfig" -}}
{{- if eq .Values.speculative.method "dflash" -}}
{"method":"dflash","model":"{{ .Values.modelPaths.dflashDraft }}","num_speculative_tokens":{{ .Values.speculative.numSpeculativeTokens }},"draft_tensor_parallel_size":{{ .Values.speculative.draftTensorParallelSize }},"disable_by_batch_size":{{ .Values.speculative.disableByBatchSize }}}
{{- else -}}
{"method":"mtp","num_speculative_tokens":{{ .Values.speculative.mtpNumSpeculativeTokens }},"disable_by_batch_size":{{ .Values.speculative.disableByBatchSize }}}
{{- end -}}
{{- end -}}
