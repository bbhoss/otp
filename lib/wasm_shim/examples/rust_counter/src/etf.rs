//! Erlang External Term Format (ETF) encoding and decoding.
//!
//! This module provides serialization and deserialization of Erlang terms
//! using the External Term Format, enabling communication between Rust
//! WASM components and the Erlang VM.

use alloc::string::String;
use alloc::vec::Vec;
use alloc::boxed::Box;
use core::fmt;

/// ETF version byte (always 131)
pub const ETF_VERSION: u8 = 131;

/// ETF type tags
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    SmallInteger = b'a',      // 97
    Integer = b'b',           // 98
    NewFloat = b'F',          // 70
    AtomUtf8 = b'v',          // 118
    SmallAtomUtf8 = b'w',     // 119
    SmallTuple = b'h',        // 104
    LargeTuple = b'i',        // 105
    Nil = b'j',               // 106
    String = b'k',            // 107
    List = b'l',              // 108
    Binary = b'm',            // 109
    Map = b't',               // 116
    NewPid = b'X',            // 88
    NewerReference = b'Z',    // 90
}

/// An Erlang term represented in Rust.
#[derive(Debug, Clone, PartialEq)]
pub enum Term {
    /// Nil (empty list)
    Nil,
    /// Atom (interned string)
    Atom(String),
    /// Integer (arbitrary precision, but we use i64)
    Integer(i64),
    /// Floating point number
    Float(f64),
    /// Binary data
    Binary(Vec<u8>),
    /// List of terms
    List(Vec<Term>),
    /// Tuple of terms
    Tuple(Vec<Term>),
    /// Map of key-value pairs
    Map(Vec<(Term, Term)>),
    /// Process ID
    Pid {
        node: String,
        num: u32,
        serial: u32,
        creation: u32,
    },
    /// Reference
    Ref {
        node: String,
        creation: u32,
        id: Vec<u32>,
    },
}

impl Term {
    /// Create a nil term
    pub fn nil() -> Self {
        Term::Nil
    }

    /// Create an atom
    pub fn atom(name: &str) -> Self {
        Term::Atom(String::from(name))
    }

    /// Create an integer
    pub fn integer(value: i64) -> Self {
        Term::Integer(value)
    }

    /// Create a float
    pub fn float(value: f64) -> Self {
        Term::Float(value)
    }

    /// Create a boolean (as atom)
    pub fn boolean(value: bool) -> Self {
        Term::Atom(String::from(if value { "true" } else { "false" }))
    }

    /// Create a binary
    pub fn binary(data: &[u8]) -> Self {
        Term::Binary(data.to_vec())
    }

    /// Create a list
    pub fn list(items: Vec<Term>) -> Self {
        Term::List(items)
    }

    /// Create a tuple
    pub fn tuple(items: Vec<Term>) -> Self {
        Term::Tuple(items)
    }

    /// Create a 2-tuple
    pub fn tuple2(a: Term, b: Term) -> Self {
        Term::Tuple(alloc::vec![a, b])
    }

    /// Create a 3-tuple
    pub fn tuple3(a: Term, b: Term, c: Term) -> Self {
        Term::Tuple(alloc::vec![a, b, c])
    }

    /// Create a 4-tuple
    pub fn tuple4(a: Term, b: Term, c: Term, d: Term) -> Self {
        Term::Tuple(alloc::vec![a, b, c, d])
    }

    /// Create a map
    pub fn map(entries: Vec<(Term, Term)>) -> Self {
        Term::Map(entries)
    }

    /// Check if this is nil
    pub fn is_nil(&self) -> bool {
        matches!(self, Term::Nil)
    }

    /// Check if this is an atom
    pub fn is_atom(&self) -> bool {
        matches!(self, Term::Atom(_))
    }

    /// Check if this is an integer
    pub fn is_integer(&self) -> bool {
        matches!(self, Term::Integer(_))
    }

    /// Check if this is a float
    pub fn is_float(&self) -> bool {
        matches!(self, Term::Float(_))
    }

    /// Check if this is a tuple
    pub fn is_tuple(&self) -> bool {
        matches!(self, Term::Tuple(_))
    }

    /// Check if this is a list
    pub fn is_list(&self) -> bool {
        matches!(self, Term::List(_) | Term::Nil)
    }

    /// Check if this is a map
    pub fn is_map(&self) -> bool {
        matches!(self, Term::Map(_))
    }

    /// Check if this atom equals the given name
    pub fn is_atom_eq(&self, name: &str) -> bool {
        match self {
            Term::Atom(s) => s == name,
            _ => false,
        }
    }

    /// Get the atom name if this is an atom
    pub fn as_atom(&self) -> Option<&str> {
        match self {
            Term::Atom(s) => Some(s),
            _ => None,
        }
    }

    /// Get the integer value if this is an integer
    pub fn as_integer(&self) -> Option<i64> {
        match self {
            Term::Integer(n) => Some(*n),
            _ => None,
        }
    }

    /// Get the float value if this is a float
    pub fn as_float(&self) -> Option<f64> {
        match self {
            Term::Float(f) => Some(*f),
            _ => None,
        }
    }

    /// Get the tuple elements if this is a tuple
    pub fn as_tuple(&self) -> Option<&[Term]> {
        match self {
            Term::Tuple(items) => Some(items),
            _ => None,
        }
    }

    /// Get tuple element at index
    pub fn tuple_element(&self, index: usize) -> Option<&Term> {
        match self {
            Term::Tuple(items) => items.get(index),
            _ => None,
        }
    }

    /// Get tuple arity
    pub fn tuple_arity(&self) -> Option<usize> {
        match self {
            Term::Tuple(items) => Some(items.len()),
            _ => None,
        }
    }

    /// Get the list elements if this is a list
    pub fn as_list(&self) -> Option<&[Term]> {
        match self {
            Term::List(items) => Some(items),
            Term::Nil => Some(&[]),
            _ => None,
        }
    }

    /// Get the binary data if this is a binary
    pub fn as_binary(&self) -> Option<&[u8]> {
        match self {
            Term::Binary(data) => Some(data),
            _ => None,
        }
    }

    /// Get the map entries if this is a map
    pub fn as_map(&self) -> Option<&[(Term, Term)]> {
        match self {
            Term::Map(entries) => Some(entries),
            _ => None,
        }
    }

    /// Look up a key in a map
    pub fn map_get(&self, key: &Term) -> Option<&Term> {
        match self {
            Term::Map(entries) => {
                for (k, v) in entries {
                    if k == key {
                        return Some(v);
                    }
                }
                None
            }
            _ => None,
        }
    }
}

/// Errors that can occur during ETF operations
#[derive(Debug)]
pub enum Error {
    /// Invalid ETF version byte
    InvalidVersion(u8),
    /// Unexpected end of input
    UnexpectedEof,
    /// Unknown or unsupported tag
    UnknownTag(u8),
    /// Invalid UTF-8 in atom
    InvalidUtf8,
    /// Buffer too small for encoding
    BufferTooSmall,
    /// Integer overflow
    Overflow,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidVersion(v) => write!(f, "invalid ETF version: {}", v),
            Error::UnexpectedEof => write!(f, "unexpected end of input"),
            Error::UnknownTag(t) => write!(f, "unknown tag: {}", t),
            Error::InvalidUtf8 => write!(f, "invalid UTF-8"),
            Error::BufferTooSmall => write!(f, "buffer too small"),
            Error::Overflow => write!(f, "integer overflow"),
        }
    }
}

/// Result type for ETF operations
pub type Result<T> = core::result::Result<T, Error>;

/// Decoder for reading ETF data
pub struct Decoder<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Decoder<'a> {
    /// Create a new decoder from a byte slice
    pub fn new(data: &'a [u8]) -> Self {
        Decoder { data, pos: 0 }
    }

    /// Decode a complete term from the data
    pub fn decode(&mut self) -> Result<Term> {
        // Check version byte
        let version = self.read_u8()?;
        if version != ETF_VERSION {
            return Err(Error::InvalidVersion(version));
        }
        self.decode_term()
    }

    fn remaining(&self) -> usize {
        self.data.len() - self.pos
    }

    fn read_u8(&mut self) -> Result<u8> {
        if self.pos >= self.data.len() {
            return Err(Error::UnexpectedEof);
        }
        let byte = self.data[self.pos];
        self.pos += 1;
        Ok(byte)
    }

    fn read_u16_be(&mut self) -> Result<u16> {
        if self.remaining() < 2 {
            return Err(Error::UnexpectedEof);
        }
        let value = u16::from_be_bytes([self.data[self.pos], self.data[self.pos + 1]]);
        self.pos += 2;
        Ok(value)
    }

    fn read_u32_be(&mut self) -> Result<u32> {
        if self.remaining() < 4 {
            return Err(Error::UnexpectedEof);
        }
        let value = u32::from_be_bytes([
            self.data[self.pos],
            self.data[self.pos + 1],
            self.data[self.pos + 2],
            self.data[self.pos + 3],
        ]);
        self.pos += 4;
        Ok(value)
    }

    fn read_i32_be(&mut self) -> Result<i32> {
        Ok(self.read_u32_be()? as i32)
    }

    fn read_bytes(&mut self, len: usize) -> Result<&'a [u8]> {
        if self.remaining() < len {
            return Err(Error::UnexpectedEof);
        }
        let bytes = &self.data[self.pos..self.pos + len];
        self.pos += len;
        Ok(bytes)
    }

    fn decode_term(&mut self) -> Result<Term> {
        let tag = self.read_u8()?;

        match tag {
            b'a' => {
                // SMALL_INTEGER
                let value = self.read_u8()? as i64;
                Ok(Term::Integer(value))
            }
            b'b' => {
                // INTEGER
                let value = self.read_i32_be()? as i64;
                Ok(Term::Integer(value))
            }
            b'F' => {
                // NEW_FLOAT
                let bytes = self.read_bytes(8)?;
                let bits = u64::from_be_bytes(bytes.try_into().unwrap());
                let value = f64::from_bits(bits);
                Ok(Term::Float(value))
            }
            b'v' => {
                // ATOM_UTF8
                let len = self.read_u16_be()? as usize;
                let bytes = self.read_bytes(len)?;
                let name = core::str::from_utf8(bytes).map_err(|_| Error::InvalidUtf8)?;
                Ok(Term::Atom(String::from(name)))
            }
            b'w' => {
                // SMALL_ATOM_UTF8
                let len = self.read_u8()? as usize;
                let bytes = self.read_bytes(len)?;
                let name = core::str::from_utf8(bytes).map_err(|_| Error::InvalidUtf8)?;
                Ok(Term::Atom(String::from(name)))
            }
            b'd' => {
                // ATOM (deprecated Latin1)
                let len = self.read_u16_be()? as usize;
                let bytes = self.read_bytes(len)?;
                // Assume ASCII for deprecated format
                let name = core::str::from_utf8(bytes).map_err(|_| Error::InvalidUtf8)?;
                Ok(Term::Atom(String::from(name)))
            }
            b's' => {
                // SMALL_ATOM (deprecated Latin1)
                let len = self.read_u8()? as usize;
                let bytes = self.read_bytes(len)?;
                let name = core::str::from_utf8(bytes).map_err(|_| Error::InvalidUtf8)?;
                Ok(Term::Atom(String::from(name)))
            }
            b'h' => {
                // SMALL_TUPLE
                let arity = self.read_u8()? as usize;
                let mut elements = Vec::with_capacity(arity);
                for _ in 0..arity {
                    elements.push(self.decode_term()?);
                }
                Ok(Term::Tuple(elements))
            }
            b'i' => {
                // LARGE_TUPLE
                let arity = self.read_u32_be()? as usize;
                let mut elements = Vec::with_capacity(arity);
                for _ in 0..arity {
                    elements.push(self.decode_term()?);
                }
                Ok(Term::Tuple(elements))
            }
            b'j' => {
                // NIL
                Ok(Term::Nil)
            }
            b'k' => {
                // STRING (list of bytes)
                let len = self.read_u16_be()? as usize;
                let bytes = self.read_bytes(len)?;
                let items: Vec<Term> = bytes.iter().map(|&b| Term::Integer(b as i64)).collect();
                Ok(Term::List(items))
            }
            b'l' => {
                // LIST
                let len = self.read_u32_be()? as usize;
                let mut elements = Vec::with_capacity(len);
                for _ in 0..len {
                    elements.push(self.decode_term()?);
                }
                // Read tail (should be NIL for proper lists)
                let tail = self.decode_term()?;
                if !tail.is_nil() {
                    // Improper list - append tail
                    elements.push(tail);
                }
                Ok(Term::List(elements))
            }
            b'm' => {
                // BINARY
                let len = self.read_u32_be()? as usize;
                let bytes = self.read_bytes(len)?;
                Ok(Term::Binary(bytes.to_vec()))
            }
            b't' => {
                // MAP
                let size = self.read_u32_be()? as usize;
                let mut entries = Vec::with_capacity(size);
                for _ in 0..size {
                    let key = self.decode_term()?;
                    let value = self.decode_term()?;
                    entries.push((key, value));
                }
                Ok(Term::Map(entries))
            }
            b'X' => {
                // NEW_PID
                let node = self.decode_term()?;
                let node_name = match node {
                    Term::Atom(s) => s,
                    _ => return Err(Error::InvalidUtf8),
                };
                let num = self.read_u32_be()?;
                let serial = self.read_u32_be()?;
                let creation = self.read_u32_be()?;
                Ok(Term::Pid {
                    node: node_name,
                    num,
                    serial,
                    creation,
                })
            }
            b'Z' => {
                // NEWER_REFERENCE
                let len = self.read_u16_be()? as usize;
                let node = self.decode_term()?;
                let node_name = match node {
                    Term::Atom(s) => s,
                    _ => return Err(Error::InvalidUtf8),
                };
                let creation = self.read_u32_be()?;
                let mut id = Vec::with_capacity(len);
                for _ in 0..len {
                    id.push(self.read_u32_be()?);
                }
                Ok(Term::Ref {
                    node: node_name,
                    creation,
                    id,
                })
            }
            _ => Err(Error::UnknownTag(tag)),
        }
    }
}

/// Encoder for writing ETF data
pub struct Encoder {
    buffer: Vec<u8>,
}

impl Encoder {
    /// Create a new encoder
    pub fn new() -> Self {
        Encoder {
            buffer: Vec::with_capacity(256),
        }
    }

    /// Encode a term and return the ETF bytes
    pub fn encode(&mut self, term: &Term) -> Result<Vec<u8>> {
        self.buffer.clear();
        self.buffer.push(ETF_VERSION);
        self.encode_term(term)?;
        Ok(self.buffer.clone())
    }

    fn write_u8(&mut self, value: u8) {
        self.buffer.push(value);
    }

    fn write_u16_be(&mut self, value: u16) {
        self.buffer.extend_from_slice(&value.to_be_bytes());
    }

    fn write_u32_be(&mut self, value: u32) {
        self.buffer.extend_from_slice(&value.to_be_bytes());
    }

    fn write_i32_be(&mut self, value: i32) {
        self.buffer.extend_from_slice(&value.to_be_bytes());
    }

    fn write_bytes(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    fn encode_term(&mut self, term: &Term) -> Result<()> {
        match term {
            Term::Nil => {
                self.write_u8(b'j');
            }
            Term::Atom(name) => {
                let bytes = name.as_bytes();
                if bytes.len() <= 255 {
                    self.write_u8(b'w'); // SMALL_ATOM_UTF8
                    self.write_u8(bytes.len() as u8);
                } else {
                    self.write_u8(b'v'); // ATOM_UTF8
                    self.write_u16_be(bytes.len() as u16);
                }
                self.write_bytes(bytes);
            }
            Term::Integer(value) => {
                if *value >= 0 && *value <= 255 {
                    self.write_u8(b'a'); // SMALL_INTEGER
                    self.write_u8(*value as u8);
                } else if *value >= i32::MIN as i64 && *value <= i32::MAX as i64 {
                    self.write_u8(b'b'); // INTEGER
                    self.write_i32_be(*value as i32);
                } else {
                    // Would need SMALL_BIG or LARGE_BIG for larger values
                    return Err(Error::Overflow);
                }
            }
            Term::Float(value) => {
                self.write_u8(b'F'); // NEW_FLOAT
                let bits = value.to_bits();
                self.write_bytes(&bits.to_be_bytes());
            }
            Term::Binary(data) => {
                self.write_u8(b'm'); // BINARY
                self.write_u32_be(data.len() as u32);
                self.write_bytes(data);
            }
            Term::List(items) => {
                if items.is_empty() {
                    self.write_u8(b'j'); // NIL
                } else {
                    self.write_u8(b'l'); // LIST
                    self.write_u32_be(items.len() as u32);
                    for item in items {
                        self.encode_term(item)?;
                    }
                    self.write_u8(b'j'); // NIL tail
                }
            }
            Term::Tuple(items) => {
                if items.len() <= 255 {
                    self.write_u8(b'h'); // SMALL_TUPLE
                    self.write_u8(items.len() as u8);
                } else {
                    self.write_u8(b'i'); // LARGE_TUPLE
                    self.write_u32_be(items.len() as u32);
                }
                for item in items {
                    self.encode_term(item)?;
                }
            }
            Term::Map(entries) => {
                self.write_u8(b't'); // MAP
                self.write_u32_be(entries.len() as u32);
                for (key, value) in entries {
                    self.encode_term(key)?;
                    self.encode_term(value)?;
                }
            }
            Term::Pid {
                node,
                num,
                serial,
                creation,
            } => {
                self.write_u8(b'X'); // NEW_PID
                self.encode_term(&Term::Atom(node.clone()))?;
                self.write_u32_be(*num);
                self.write_u32_be(*serial);
                self.write_u32_be(*creation);
            }
            Term::Ref {
                node,
                creation,
                id,
            } => {
                self.write_u8(b'Z'); // NEWER_REFERENCE
                self.write_u16_be(id.len() as u16);
                self.encode_term(&Term::Atom(node.clone()))?;
                self.write_u32_be(*creation);
                for n in id {
                    self.write_u32_be(*n);
                }
            }
        }
        Ok(())
    }
}

impl Default for Encoder {
    fn default() -> Self {
        Self::new()
    }
}

/// Decode a term from ETF bytes
pub fn decode(data: &[u8]) -> Result<Term> {
    let mut decoder = Decoder::new(data);
    decoder.decode()
}

/// Encode a term to ETF bytes
pub fn encode(term: &Term) -> Result<Vec<u8>> {
    let mut encoder = Encoder::new();
    encoder.encode(term)
}
