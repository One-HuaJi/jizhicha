use thiserror::Error;

pub type Result<T> = std::result::Result<T, HuseVpnError>;

#[derive(Debug, Error)]
pub enum HuseVpnError {
    #[error("TLS error: {0}")]
    Tls(String),
    #[error("school accelerator authentication failed: {0}")]
    Authentication(String),
    #[error("NC protocol error: {0}")]
    Protocol(String),
    #[error("tunnel error: {0}")]
    Tunnel(String),
    #[error("network I/O error: {0}")]
    Io(#[from] std::io::Error),
}
