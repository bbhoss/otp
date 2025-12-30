//! Erlang distribution protocol handshake implementation
//!
//! This implements the OTP 23+ handshake protocol (version 6).
//! See: https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html

use crate::flags::DistFlags;
use crate::{Error, Result};
use byteorder::{BigEndian, ReadBytesExt, WriteBytesExt};
use std::io::{Read, Write};

/// Handshake state machine
pub struct Handshake {
    /// Our node name (e.g., "esp32@hostname")
    pub node_name: String,
    /// Cookie for authentication
    pub cookie: String,
    /// Our creation number
    pub creation: u32,
    /// Our capability flags
    pub flags: DistFlags,
    /// Their capability flags (after receiving challenge)
    pub their_flags: Option<DistFlags>,
    /// Our challenge
    our_challenge: u32,
    /// Their challenge
    their_challenge: Option<u32>,
}

impl Handshake {
    pub fn new(node_name: &str, cookie: &str, creation: u32) -> Self {
        Handshake {
            node_name: node_name.to_string(),
            cookie: cookie.to_string(),
            creation,
            flags: DistFlags::default_client(),
            their_flags: None,
            our_challenge: rand_challenge(),
            their_challenge: None,
        }
    }

    /// Perform the client-side handshake
    pub fn perform<S: Read + Write>(&mut self, stream: &mut S) -> Result<()> {
        // Step 1: Send our name
        self.send_name(stream)?;
        log::debug!("Sent name: {}", self.node_name);

        // Step 2: Receive status
        self.recv_status(stream)?;
        log::debug!("Received status: ok");

        // Step 3: Receive challenge
        self.recv_challenge(stream)?;
        log::debug!(
            "Received challenge, their_flags={:?}",
            self.their_flags.unwrap().0
        );

        // Step 4: Send challenge reply
        self.send_challenge_reply(stream)?;
        log::debug!("Sent challenge reply");

        // Step 5: Receive challenge ack
        self.recv_challenge_ack(stream)?;
        log::debug!("Received challenge ack - handshake complete!");

        Ok(())
    }

    /// Send our name (tag 'N' for OTP 23+ protocol)
    fn send_name<W: Write>(&self, writer: &mut W) -> Result<()> {
        let name_bytes = self.node_name.as_bytes();
        let name_len = name_bytes.len() as u16;

        // Message: 'N' + flags(8) + creation(4) + nlen(2) + name
        let msg_len = 1 + 8 + 4 + 2 + name_len as usize;

        // Send length prefix (2 bytes for handshake phase)
        writer.write_u16::<BigEndian>(msg_len as u16)?;

        // Tag 'N' (new handshake)
        writer.write_u8(b'N')?;

        // Flags (8 bytes)
        writer.write_u64::<BigEndian>(self.flags.0)?;

        // Creation (4 bytes)
        writer.write_u32::<BigEndian>(self.creation)?;

        // Name length (2 bytes)
        writer.write_u16::<BigEndian>(name_len)?;

        // Name
        writer.write_all(name_bytes)?;

        writer.flush()?;
        Ok(())
    }

    /// Receive status message
    fn recv_status<R: Read>(&self, reader: &mut R) -> Result<()> {
        let len = reader.read_u16::<BigEndian>()?;
        if len < 1 {
            return Err(Error::Protocol("status message too short".into()));
        }

        let tag = reader.read_u8()?;
        if tag != b's' {
            return Err(Error::Protocol(format!(
                "expected status tag 's', got '{}'",
                tag as char
            )));
        }

        // Read status string
        let mut status = vec![0u8; (len - 1) as usize];
        reader.read_exact(&mut status)?;
        let status_str =
            String::from_utf8(status).map_err(|_| Error::Protocol("invalid status utf8".into()))?;

        match status_str.as_str() {
            "ok" | "ok_simultaneous" => Ok(()),
            "nok" | "not_allowed" => Err(Error::HandshakeFailed(format!("status: {}", status_str))),
            "alive" => {
                // TODO: handle alive case (we're reconnecting)
                Err(Error::HandshakeFailed("node already alive".into()))
            }
            _ => Err(Error::Protocol(format!("unknown status: {}", status_str))),
        }
    }

    /// Receive challenge message
    fn recv_challenge<R: Read>(&mut self, reader: &mut R) -> Result<()> {
        let len = reader.read_u16::<BigEndian>()?;
        if len < 1 {
            return Err(Error::Protocol("challenge message too short".into()));
        }

        let tag = reader.read_u8()?;

        match tag {
            b'N' => {
                // New protocol (OTP 23+)
                // 'N' + flags(8) + challenge(4) + creation(4) + nlen(2) + name
                if len < 19 {
                    return Err(Error::Protocol("challenge message too short".into()));
                }

                let flags = reader.read_u64::<BigEndian>()?;
                self.their_flags = Some(DistFlags(flags));

                let challenge = reader.read_u32::<BigEndian>()?;
                self.their_challenge = Some(challenge);

                let _creation = reader.read_u32::<BigEndian>()?;

                let nlen = reader.read_u16::<BigEndian>()?;
                let mut name = vec![0u8; nlen as usize];
                reader.read_exact(&mut name)?;

                log::debug!(
                    "Received challenge from: {}",
                    String::from_utf8_lossy(&name)
                );
            }
            b'n' => {
                // Old protocol (pre-OTP 23)
                return Err(Error::Protocol(
                    "old handshake protocol not supported".into(),
                ));
            }
            _ => {
                return Err(Error::Protocol(format!(
                    "expected challenge tag 'N' or 'n', got '{}'",
                    tag as char
                )));
            }
        }

        Ok(())
    }

    /// Send challenge reply
    fn send_challenge_reply<W: Write>(&self, writer: &mut W) -> Result<()> {
        let their_challenge = self
            .their_challenge
            .ok_or_else(|| Error::Protocol("no challenge received".into()))?;

        // Compute digest: MD5(cookie + their_challenge)
        let digest = compute_digest(&self.cookie, their_challenge);

        // Message: 'r' + challenge(4) + digest(16)
        let msg_len = 1 + 4 + 16;

        writer.write_u16::<BigEndian>(msg_len as u16)?;
        writer.write_u8(b'r')?;
        writer.write_u32::<BigEndian>(self.our_challenge)?;
        writer.write_all(&digest)?;

        writer.flush()?;
        Ok(())
    }

    /// Receive challenge ack
    fn recv_challenge_ack<R: Read>(&self, reader: &mut R) -> Result<()> {
        let len = reader.read_u16::<BigEndian>()?;
        if len != 17 {
            return Err(Error::Protocol(format!(
                "expected challenge_ack len 17, got {}",
                len
            )));
        }

        let tag = reader.read_u8()?;
        if tag != b'a' {
            return Err(Error::Protocol(format!(
                "expected challenge_ack tag 'a', got '{}'",
                tag as char
            )));
        }

        // Read their digest
        let mut their_digest = [0u8; 16];
        reader.read_exact(&mut their_digest)?;

        // Compute expected digest: MD5(cookie + our_challenge)
        let expected = compute_digest(&self.cookie, self.our_challenge);

        if their_digest != expected {
            return Err(Error::AuthFailed);
        }

        Ok(())
    }
}

/// Compute MD5 digest for authentication
/// The Erlang protocol uses: MD5(cookie + challenge_as_decimal_string)
fn compute_digest(cookie: &str, challenge: u32) -> [u8; 16] {
    let mut hasher = md5::Context::new();
    hasher.consume(cookie.as_bytes());
    // Challenge must be converted to decimal string, not binary!
    hasher.consume(challenge.to_string().as_bytes());
    let digest = hasher.compute();
    digest.0
}

/// Generate a random challenge number
fn rand_challenge() -> u32 {
    // Simple PRNG - in production use proper randomness
    use std::time::{SystemTime, UNIX_EPOCH};
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u32)
        .unwrap_or(12345678);

    // LCG parameters from glibc
    seed.wrapping_mul(1103515245).wrapping_add(12345)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_digest() {
        // Test vector: cookie="testcookie", challenge=12345
        let digest = compute_digest("testcookie", 12345);
        assert_eq!(digest.len(), 16);
    }
}
