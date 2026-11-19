#!/usr/bin/env bash
# Helm post-renderer for the Volcano install (RUNBOOK 1.2): removes
# "priorityClassName: system-cluster-critical" from Volcano's pods. That class is meant for
# cluster system components; on a production cluster our test pods must not be able to
# pre-empt other workloads. Reads the rendered manifests on stdin, writes them to stdout.
exec sed '/priorityClassName: *system-cluster-critical/d'
