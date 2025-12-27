---
title: {{ .Title }}
date: {{ .Date.Format "2006-01-02" }}
draft: {{ .Draft }}
{{- with .Params.tags }}
tags:
{{- range . }}
  - {{ . }}
{{- end }}
{{- end }}
{{- with .Params.categories }}
categories:
{{- range . }}
  - {{ . }}
{{- end }}
{{- end }}
{{- with .Params.series }}
series:
{{- range . }}
  - {{ . }}
{{- end }}
{{- end }}
---

{{ .Page.RawContent }}
