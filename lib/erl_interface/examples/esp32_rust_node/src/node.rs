//! C-Node implementation for connecting to Erlang nodes

use crate::handshake::Handshake;
use crate::message::{self, ReceivedMessage};
use crate::term::{ErlPid, Term};
use crate::{Error, Result};
use std::io::{BufReader, BufWriter};
use std::net::TcpStream;
use std::sync::atomic::{AtomicU32, Ordering};

/// An Erlang C-Node
///
/// Represents this process as a node in the Erlang distribution.
pub struct CNode {
    /// Node name (alive name, e.g., "esp32")
    alive_name: String,
    /// Full node name (e.g., "esp32@hostname")
    full_name: String,
    /// Host name
    host_name: String,
    /// Cookie for authentication
    cookie: String,
    /// Creation number (for pids/refs)
    creation: u32,
    /// Counter for generating unique pids
    pid_counter: AtomicU32,
    /// TCP connection to remote node
    connection: Option<Connection>,
}

struct Connection {
    reader: BufReader<TcpStream>,
    writer: BufWriter<TcpStream>,
}

impl CNode {
    /// Create a new C-Node
    ///
    /// # Arguments
    /// * `alive_name` - The short name of this node (e.g., "esp32")
    /// * `host_name` - The host name (e.g., "esp32host")
    /// * `cookie` - The Erlang cookie for authentication
    pub fn new(alive_name: &str, host_name: &str, cookie: &str) -> Self {
        let full_name = format!("{}@{}", alive_name, host_name);

        // Use a pseudo-random creation based on time
        let creation = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| (d.as_secs() & 0x3FFFF) as u32 + 0xE10000)
            .unwrap_or(0xE10001);

        CNode {
            alive_name: alive_name.to_string(),
            full_name,
            host_name: host_name.to_string(),
            cookie: cookie.to_string(),
            creation,
            pid_counter: AtomicU32::new(0),
            connection: None,
        }
    }

    /// Connect to an Erlang node at the specified address and port
    ///
    /// This bypasses EPMD and connects directly to the node's distribution port.
    pub fn connect(&mut self, host: &str, port: u16) -> Result<()> {
        log::info!("Connecting to {}:{}...", host, port);

        // Establish TCP connection
        let addr = format!("{}:{}", host, port);
        let stream = TcpStream::connect(&addr)?;

        // Set socket options
        stream.set_nodelay(true)?;

        // Clone for reader/writer
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut writer = BufWriter::new(stream);

        // Perform handshake using the same reader/writer we'll use later
        let mut handshake = Handshake::new(&self.full_name, &self.cookie, self.creation);
        {
            let mut combined = HandshakeStream {
                reader: &mut reader,
                writer: &mut writer,
            };
            handshake.perform(&mut combined)?;
        }

        self.connection = Some(Connection { reader, writer });

        log::info!("Connected to Erlang node!");
        Ok(())
    }

    /// Get our self pid
    pub fn self_pid(&self) -> ErlPid {
        let id = self.pid_counter.fetch_add(1, Ordering::SeqCst);
        ErlPid::new(&self.full_name, id, 0, self.creation)
    }

    /// Send a message to a registered process
    pub fn reg_send(&mut self, name: &str, message: Term) -> Result<()> {
        // Get pid first before borrowing connection
        let from_pid = self.self_pid();

        let conn = self.connection.as_mut().ok_or(Error::NotConnected)?;

        log::debug!("Sending to '{}': {:?}", name, message);

        let data = message::encode_reg_send(&from_pid, name, &message)?;
        message::write_message(&mut conn.writer, &data)?;

        Ok(())
    }

    /// Send a message to a specific pid
    pub fn send(&mut self, to: &ErlPid, message: Term) -> Result<()> {
        // Get pid first before borrowing connection
        let from_pid = self.self_pid();

        let conn = self.connection.as_mut().ok_or(Error::NotConnected)?;

        log::debug!("Sending to {:?}: {:?}", to, message);

        let data = message::encode_send(&from_pid, to, &message)?;
        message::write_message(&mut conn.writer, &data)?;

        Ok(())
    }

    /// Receive a message (blocking)
    pub fn receive(&mut self) -> Result<ReceivedMessage> {
        let conn = self.connection.as_mut().ok_or(Error::NotConnected)?;
        message::read_message(&mut conn.reader)
    }

    /// Check if connected
    pub fn is_connected(&self) -> bool {
        self.connection.is_some()
    }

    /// Get the full node name
    pub fn node_name(&self) -> &str {
        &self.full_name
    }

    /// Disconnect from the remote node
    pub fn disconnect(&mut self) {
        self.connection = None;
    }
}

/// Helper struct for handshake that needs both read and write
struct HandshakeStream<'a> {
    reader: &'a mut BufReader<TcpStream>,
    writer: &'a mut BufWriter<TcpStream>,
}

impl<'a> std::io::Read for HandshakeStream<'a> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.reader.read(buf)
    }
}

impl<'a> std::io::Write for HandshakeStream<'a> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.writer.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.writer.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_node_creation() {
        let node = CNode::new("test", "localhost", "cookie");
        assert_eq!(node.node_name(), "test@localhost");
    }

    #[test]
    fn test_self_pid() {
        let node = CNode::new("test", "localhost", "cookie");
        let pid1 = node.self_pid();
        let pid2 = node.self_pid();
        assert_ne!(pid1.id, pid2.id);
    }
}
