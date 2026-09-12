#!/usr/bin/env bash
# Sourced by verdict scripts. The private sidecar carries every result, including quiet passes.
# The wrapper converts TSV to JSON; tabs/newlines in detail are flattened before writing.
record() {
    [ -n "${INFRA_CHECKS_FILE:-}" ] || return 0
    local detail=${2//$'\t'/ }
    detail=${detail//$'\n'/ }
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${CHECK_ID:-collector}" "${CHECK_CATEGORY:-monitoring}" "$1" \
        "${CHECK_OBSERVATION:-observed}" "${CHECK_ADVISORY:-false}" "$detail" >> "$INFRA_CHECKS_FILE"
}
