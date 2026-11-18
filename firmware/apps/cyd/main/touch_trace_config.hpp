#pragma once

namespace vault::idf {
// TEMPORARY diagnostic image. It preserves input decisions but replaces USB
// service dispatch with an explicit, bounded !trace capture. Restore false
// before a normal M3 acceptance build; NVS and the gameplay wire are unchanged.
inline constexpr bool touch_trace_build = false;
// This separate debug image accepts only the read-only !netdiag USB query.
inline constexpr bool network_diagnostics_build = true;
static_assert(!(touch_trace_build && network_diagnostics_build));
inline constexpr const char* firmware_name = touch_trace_build
    ? "vault-cyd-m3-touch-trace" : network_diagnostics_build
    ? "vault-cyd-m3-network-diagnostics" : "vault-cyd-m3";
}
