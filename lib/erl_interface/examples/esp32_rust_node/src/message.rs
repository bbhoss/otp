//! Erlang distribution message encoding/decoding
//!
//! Messages use pass-through mode (no atom cache) for simplicity.

use crate::term::{ErlPid, Term};
use crate::{Error, Result};
use byteorder::{BigEndian, ReadBytesExt, WriteBytesExt};
use std::io::{Read, Write};

/// Distribution message types (control message tags)
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DistOp {
    Link = 1,
    Send = 2,
    Exit = 3,
    Unlink = 4,
    RegSend = 6,
    GroupLeader = 7,
    Exit2 = 8,
    SendTT = 12,
    ExitTT = 13,
    RegSendTT = 16,
    Exit2TT = 18,
    MonitorP = 19,
    DemonitorP = 20,
    MonitorPExit = 21,
    SendSender = 22,
    SendSenderTT = 23,
    PayloadExit = 24,
    PayloadExitTT = 25,
    PayloadExit2 = 26,
    PayloadExit2TT = 27,
    PayloadMonitorPExit = 28,
    Spawn = 29,
    SpawnReply = 30,
    SpawnReplyTT = 31,
    Unlink2 = 32,
    UnlinkAck = 33,
    AliasSend = 34,
    AliasSendTT = 35,
}

/// Message pass-through header (no atom cache)
const PASS_THROUGH: u8 = 112; // 'p'
const VERSION_MAGIC: u8 = 131;

/// Send a REG_SEND message (send to registered process)
pub fn encode_reg_send(from: &ErlPid, to_name: &str, message: &Term) -> Result<Vec<u8>> {
    // Control message: {REG_SEND, FromPid, Cookie, ToName}
    let control = Term::tuple(vec![
        Term::integer(DistOp::RegSend as i64),
        Term::Pid(from.clone()),
        Term::atom(""), // Cookie placeholder (unused in pass-through)
        Term::atom(to_name),
    ]);

    encode_message(&control, Some(message))
}

/// Send a SEND message (send to pid)
pub fn encode_send(from: &ErlPid, to: &ErlPid, message: &Term) -> Result<Vec<u8>> {
    // Control message: {SEND, Cookie, ToPid}
    let control = Term::tuple(vec![
        Term::integer(DistOp::Send as i64),
        Term::atom(""), // Cookie placeholder
        Term::Pid(to.clone()),
    ]);

    encode_message(&control, Some(message))
}

/// Encode a distribution message
fn encode_message(control: &Term, payload: Option<&Term>) -> Result<Vec<u8>> {
    let mut buf = Vec::new();

    // We'll write the length at the end, reserve 4 bytes
    buf.write_u32::<BigEndian>(0)?;

    // Pass-through header
    buf.push(PASS_THROUGH);

    // Control message with version tag
    buf.push(VERSION_MAGIC);
    let control_bytes = control.encode()?;
    log::debug!("Control bytes (raw): {:02x?}", &control_bytes);
    // Skip the version byte from eetf encoding (it includes 131)
    buf.extend_from_slice(&control_bytes[1..]);

    // Payload message (if present)
    if let Some(msg) = payload {
        buf.push(VERSION_MAGIC);
        let msg_bytes = msg.encode()?;
        log::debug!("Payload bytes (raw): {:02x?}", &msg_bytes);
        buf.extend_from_slice(&msg_bytes[1..]);
    }

    // Write the length (excluding the 4-byte length field itself)
    let msg_len = (buf.len() - 4) as u32;
    buf[0..4].copy_from_slice(&msg_len.to_be_bytes());

    log::debug!("Final message bytes: {:02x?}", &buf);
    Ok(buf)
}

/// Received message from Erlang
#[derive(Debug)]
pub struct ReceivedMessage {
    pub control: Term,
    pub payload: Option<Term>,
}

/// Read a distribution message
pub fn read_message<R: Read>(reader: &mut R) -> Result<ReceivedMessage> {
    // Read length (4 bytes in data phase)
    let len = reader.read_u32::<BigEndian>()?;
    if len == 0 {
        return Err(Error::Protocol("empty message".into()));
    }

    // Read the entire message
    let mut data = vec![0u8; len as usize];
    reader.read_exact(&mut data)?;

    // Check pass-through header
    if data[0] != PASS_THROUGH {
        return Err(Error::Protocol(format!(
            "expected pass-through header, got {}",
            data[0]
        )));
    }

    let mut cursor = std::io::Cursor::new(&data[1..]);

    // Read control message
    let control = Term::decode_from(&mut cursor)?;

    // Read payload if present
    let payload = if cursor.position() < (data.len() - 1) as u64 {
        Some(Term::decode_from(&mut cursor)?)
    } else {
        None
    };

    Ok(ReceivedMessage { control, payload })
}

/// Write raw bytes to stream with length prefix
pub fn write_message<W: Write>(writer: &mut W, data: &[u8]) -> Result<()> {
    writer.write_all(data)?;
    writer.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_reg_send() {
        let pid = ErlPid::new("test@localhost", 0, 0, 1);
        let msg = Term::atom("hello");
        let encoded = encode_reg_send(&pid, "echo", &msg).unwrap();
        assert!(!encoded.is_empty());
        // Should start with length prefix
        assert!(encoded.len() > 4);
    }
}
