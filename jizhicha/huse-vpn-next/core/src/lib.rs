//! Verified protocol core for the HUSE Gateway/SecWorld VPN replacement.

pub mod error;
pub mod nc;
pub mod sac;
pub mod tls;

#[cfg(windows)]
pub mod tunnel;

#[cfg(target_os = "android")]
pub mod tunnel_android;

pub use error::{HuseVpnError, Result};

/// Whether verbose packet/record telemetry is enabled.
///
/// Telemetry prints real IPv4 source/destination addresses (including internal
/// campus destinations) and record sizes. It is strictly opt-in so release
/// builds never leak network topology into device logs.
pub(crate) fn packet_trace_enabled() -> bool {
    std::env::var_os("HUSE_VPN_PACKET_TRACE").is_some()
}
