{{/* Comma-joined rail NAD annotation value, e.g. rail0,rail1,...,rail7 */}}
{{- define "glm51.railAnnotation" -}}
{{- join "," .Values.rails -}}
{{- end -}}

{{/*
Low-latency pod contract (§3.3 / §10): pairs with runtimeClassName (values
runtimeClassName) on GPU workers. irq-load-balancing steers device IRQs off the
pod's exclusive cores; cpu-quota removes CFS throttling from the hot loop.
*/}}
{{- define "glm51.lowLatencyAnnotations" -}}
irq-load-balancing.crio.io: "disable"
cpu-quota.crio.io: "disable"
{{- end -}}

{{/*
Collective/transfer env vars (NCCL + UCX), §3.4. Rendered as DynamoGraphDeployment
envs[] entries. Call with the root context. Indent at the call site.
*/}}
{{- define "glm51.fabricEnv" -}}
- {name: NCCL_SOCKET_IFNAME, value: "eth0"}
- {name: NCCL_IB_HCA, value: "{{ .Values.fabric.ncclHca }}"}
- {name: NCCL_IB_GID_INDEX, value: "{{ .Values.fabric.gidIndex }}"}
- {name: NCCL_IB_TC, value: "{{ .Values.fabric.trafficClass }}"}
- {name: NCCL_IB_QPS_PER_CONNECTION, value: "4"}
- {name: NCCL_IB_PCI_RELAXED_ORDERING, value: "1"}
- {name: NCCL_CROSS_NIC, value: "0"}
- {name: UCX_TLS, value: "rc,cuda_copy,cuda_ipc"}
- {name: UCX_NET_DEVICES, value: "{{ .Values.fabric.ucxNetDevices }}"}
- {name: UCX_IB_GID_INDEX, value: "{{ .Values.fabric.gidIndex }}"}
- {name: UCX_IB_TRAFFIC_CLASS, value: "{{ .Values.fabric.trafficClass }}"}
{{- end -}}
