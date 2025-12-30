//! # erlang_node
//!
//! A minimal, synchronous Erlang distribution protocol implementation
//! designed for embedded systems like ESP32.
//!
//! This library provides the ability to:
//! - Connect to an Erlang node as a "C node"
//! - Send messages to registered processes
//! - Receive messages from Erlang processes
//!
//! ## Example
//!
//! ```no_run
//! use erlang_node::{CNode, Term};
//!
//! let mut node = CNode::new("esp32", "esp32host", "secret_cookie");
//! node.connect("10.0.2.2", 9000).unwrap();
//! node.reg_send("echo_server", Term::atom("hello")).unwrap();
//! ```

pub mod handshake;
pub mod message;
pub mod node;
pub mod term;

pub use node::CNode;
pub use term::Term;

/// Distribution protocol flags
pub mod flags {
    use std::ops::BitOr;

    /// Distribution flags as defined in the Erlang distribution protocol
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct DistFlags(pub u64);

    impl DistFlags {
        pub const PUBLISHED: DistFlags = DistFlags(0x1);
        pub const ATOM_CACHE: DistFlags = DistFlags(0x2);
        pub const EXTENDED_REFERENCES: DistFlags = DistFlags(0x4);
        pub const DIST_MONITOR: DistFlags = DistFlags(0x8);
        pub const FUN_TAGS: DistFlags = DistFlags(0x10);
        pub const DIST_MONITOR_NAME: DistFlags = DistFlags(0x20);
        pub const HIDDEN_ATOM_CACHE: DistFlags = DistFlags(0x40);
        pub const NEW_FUN_TAGS: DistFlags = DistFlags(0x80);
        pub const EXTENDED_PIDS_PORTS: DistFlags = DistFlags(0x100);
        pub const EXPORT_PTR_TAG: DistFlags = DistFlags(0x200);
        pub const BIT_BINARIES: DistFlags = DistFlags(0x400);
        pub const NEW_FLOATS: DistFlags = DistFlags(0x800);
        pub const UNICODE_IO: DistFlags = DistFlags(0x1000);
        pub const DIST_HDR_ATOM_CACHE: DistFlags = DistFlags(0x2000);
        pub const SMALL_ATOM_TAGS: DistFlags = DistFlags(0x4000);
        pub const UTF8_ATOMS: DistFlags = DistFlags(0x10000);
        pub const MAP_TAG: DistFlags = DistFlags(0x20000);
        pub const BIG_CREATION: DistFlags = DistFlags(0x40000);
        pub const SEND_SENDER: DistFlags = DistFlags(0x80000);
        pub const BIG_SEQTRACE_LABELS: DistFlags = DistFlags(0x100000);
        pub const EXIT_PAYLOAD: DistFlags = DistFlags(0x400000);
        pub const FRAGMENTS: DistFlags = DistFlags(0x800000);
        pub const HANDSHAKE_23: DistFlags = DistFlags(0x1000000);
        pub const UNLINK_ID: DistFlags = DistFlags(0x2000000);
        pub const MANDATORY_25_DIGEST: DistFlags = DistFlags(1 << 36);
        pub const SPAWN: DistFlags = DistFlags(1 << 32);
        pub const NAME_ME: DistFlags = DistFlags(1 << 33);
        pub const V4_NC: DistFlags = DistFlags(1 << 34);
        pub const ALIAS: DistFlags = DistFlags(1 << 35);

        /// Minimum flags required for OTP 25+ compatibility
        pub fn default_client() -> DistFlags {
            Self::PUBLISHED
                | Self::EXTENDED_REFERENCES
                | Self::DIST_MONITOR
                | Self::DIST_MONITOR_NAME
                | Self::FUN_TAGS
                | Self::NEW_FUN_TAGS
                | Self::EXTENDED_PIDS_PORTS
                | Self::EXPORT_PTR_TAG
                | Self::BIT_BINARIES
                | Self::NEW_FLOATS
                | Self::SMALL_ATOM_TAGS
                | Self::UTF8_ATOMS
                | Self::MAP_TAG
                | Self::BIG_CREATION
                | Self::HANDSHAKE_23
                | Self::V4_NC
        }

        pub fn contains(&self, other: DistFlags) -> bool {
            (self.0 & other.0) == other.0
        }
    }

    impl BitOr for DistFlags {
        type Output = Self;
        fn bitor(self, rhs: Self) -> Self::Output {
            DistFlags(self.0 | rhs.0)
        }
    }
}

/// Error types for the library
#[derive(Debug)]
pub enum Error {
    /// IO error during network operations
    Io(std::io::Error),
    /// Handshake failed
    HandshakeFailed(String),
    /// Authentication failed (wrong cookie)
    AuthFailed,
    /// Protocol error
    Protocol(String),
    /// Term encoding/decoding error
    Term(String),
    /// Not connected
    NotConnected,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(e) => write!(f, "IO error: {}", e),
            Error::HandshakeFailed(s) => write!(f, "Handshake failed: {}", s),
            Error::AuthFailed => write!(f, "Authentication failed"),
            Error::Protocol(s) => write!(f, "Protocol error: {}", s),
            Error::Term(s) => write!(f, "Term error: {}", s),
            Error::NotConnected => write!(f, "Not connected"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_flags() {
        let flags = flags::DistFlags::default_client();
        assert!(flags.contains(flags::DistFlags::HANDSHAKE_23));
        assert!(flags.contains(flags::DistFlags::UTF8_ATOMS));
    }
}
