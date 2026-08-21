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
