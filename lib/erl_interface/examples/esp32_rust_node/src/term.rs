//! Erlang term types, wrapping the eetf crate for convenience

use eetf::{self, Atom, BigInteger, Binary, List, Map, Pid, Port, Reference, Tuple};
use std::collections::HashMap;
use std::io::Read;

/// An Erlang term
#[derive(Debug, Clone, PartialEq)]
pub enum Term {
    Atom(String),
    Integer(i64),
    Float(f64),
    Binary(Vec<u8>),
    String(String),
    List(Vec<Term>),
    Tuple(Vec<Term>),
    Map(Vec<(Term, Term)>),
    Pid(ErlPid),
    Port(ErlPort),
    Reference(ErlRef),
    BigInt(i64), // Simplified - just use i64 for now
    Nil,
}

/// Erlang process identifier
#[derive(Debug, Clone, PartialEq)]
pub struct ErlPid {
    pub node: String,
    pub id: u32,
    pub serial: u32,
    pub creation: u32,
}

/// Erlang port identifier
#[derive(Debug, Clone, PartialEq)]
pub struct ErlPort {
    pub node: String,
    pub id: u64,
    pub creation: u32,
}

/// Erlang reference
#[derive(Debug, Clone, PartialEq)]
pub struct ErlRef {
    pub node: String,
    pub id: Vec<u32>,
    pub creation: u32,
}

impl Term {
    /// Create an atom term
    pub fn atom(s: &str) -> Term {
        Term::Atom(s.to_string())
    }

    /// Create an integer term
    pub fn integer(n: i64) -> Term {
        Term::Integer(n)
    }

    /// Create a binary term
    pub fn binary(data: &[u8]) -> Term {
        Term::Binary(data.to_vec())
    }

    /// Create a string term (stored as binary)
    pub fn string(s: &str) -> Term {
        Term::String(s.to_string())
    }

    /// Create a tuple term
    pub fn tuple(elements: Vec<Term>) -> Term {
        Term::Tuple(elements)
    }

    /// Create a list term
    pub fn list(elements: Vec<Term>) -> Term {
        Term::List(elements)
    }

    /// Create a nil/empty list term
    pub fn nil() -> Term {
        Term::Nil
    }

    /// Encode term to External Term Format bytes
    pub fn encode(&self) -> crate::Result<Vec<u8>> {
        let eetf_term = self.to_eetf()?;
        let mut buf = Vec::new();
        eetf_term
            .encode(&mut buf)
            .map_err(|e| crate::Error::Term(format!("encode error: {}", e)))?;
        Ok(buf)
    }

    /// Decode term from External Term Format bytes
    pub fn decode(data: &[u8]) -> crate::Result<Term> {
        let mut cursor = std::io::Cursor::new(data);
        let eetf_term = eetf::Term::decode(&mut cursor)
            .map_err(|e| crate::Error::Term(format!("decode error: {}", e)))?;
        Term::from_eetf(&eetf_term)
    }

    /// Decode term from a reader
    pub fn decode_from<R: Read>(reader: &mut R) -> crate::Result<Term> {
        let eetf_term = eetf::Term::decode(reader)
            .map_err(|e| crate::Error::Term(format!("decode error: {}", e)))?;
        Term::from_eetf(&eetf_term)
    }

    /// Convert to eetf Term
    fn to_eetf(&self) -> crate::Result<eetf::Term> {
        Ok(match self {
            Term::Atom(s) => eetf::Term::Atom(Atom::from(s.as_str())),
            Term::Integer(n) => eetf::Term::FixInteger(eetf::FixInteger { value: *n as i32 }),
            Term::Float(f) => eetf::Term::Float(eetf::Float { value: *f }),
            Term::Binary(data) => eetf::Term::Binary(Binary::from(data.as_slice())),
            Term::String(s) => {
                // Encode as binary for simplicity
                eetf::Term::Binary(Binary::from(s.as_bytes()))
            }
            Term::List(items) => {
                let elements: Result<Vec<_>, _> = items.iter().map(|t| t.to_eetf()).collect();
                eetf::Term::List(List::from(elements?))
            }
            Term::Tuple(items) => {
                let elements: Result<Vec<_>, _> = items.iter().map(|t| t.to_eetf()).collect();
                eetf::Term::Tuple(Tuple::from(elements?))
            }
            Term::Map(pairs) => {
                let mut map = HashMap::new();
                for (k, v) in pairs {
                    map.insert(k.to_eetf()?, v.to_eetf()?);
                }
                eetf::Term::Map(Map { map })
            }
            Term::Pid(pid) => eetf::Term::Pid(Pid {
                node: Atom::from(pid.node.as_str()),
                id: pid.id,
                serial: pid.serial,
                creation: pid.creation,
            }),
            Term::Port(port) => eetf::Term::Port(Port {
                node: Atom::from(port.node.as_str()),
                id: port.id,
                creation: port.creation,
            }),
            Term::Reference(r) => eetf::Term::Reference(Box::new(Reference {
                node: Atom::from(r.node.as_str()),
                id: r.id.clone(),
                creation: r.creation,
            })),
            Term::BigInt(n) => eetf::Term::BigInteger(BigInteger::from(*n)),
            Term::Nil => eetf::Term::List(List::nil()),
        })
    }

    /// Convert from eetf Term
    fn from_eetf(term: &eetf::Term) -> crate::Result<Term> {
        use num_traits::ToPrimitive;

        Ok(match term {
            eetf::Term::Atom(a) => Term::Atom(a.name.clone()),
            eetf::Term::FixInteger(n) => Term::Integer(n.value as i64),
            eetf::Term::BigInteger(n) => {
                // Try to convert to i64, fall back to 0 if too big
                Term::BigInt(n.value.to_i64().unwrap_or(0))
            }
            eetf::Term::Float(f) => Term::Float(f.value),
            eetf::Term::Binary(b) => Term::Binary(b.bytes.clone()),
            eetf::Term::ByteList(s) => Term::String(
                std::str::from_utf8(&s.bytes)
                    .unwrap_or("<invalid utf8>")
                    .to_string(),
            ),
            eetf::Term::List(list) => {
                if list.elements.is_empty() {
                    Term::Nil
                } else {
                    let elements: Result<Vec<_>, _> =
                        list.elements.iter().map(Term::from_eetf).collect();
                    Term::List(elements?)
                }
            }
            eetf::Term::Tuple(tuple) => {
                let elements: Result<Vec<_>, _> =
                    tuple.elements.iter().map(Term::from_eetf).collect();
                Term::Tuple(elements?)
            }
            eetf::Term::Map(map) => {
                let mut pairs = Vec::new();
                for (k, v) in map.map.iter() {
                    pairs.push((Term::from_eetf(k)?, Term::from_eetf(v)?));
                }
                Term::Map(pairs)
            }
            eetf::Term::Pid(pid) => Term::Pid(ErlPid {
                node: pid.node.name.clone(),
                id: pid.id,
                serial: pid.serial,
                creation: pid.creation,
            }),
            eetf::Term::Port(port) => Term::Port(ErlPort {
                node: port.node.name.clone(),
                id: port.id,
                creation: port.creation,
            }),
            eetf::Term::Reference(r) => Term::Reference(ErlRef {
                node: r.node.name.clone(),
                id: r.id.clone(),
                creation: r.creation,
            }),
            eetf::Term::BitBinary(b) => Term::Binary(b.bytes.clone()),
            eetf::Term::ExternalFun(_) => {
                return Err(crate::Error::Term("external fun not supported".into()))
            }
            eetf::Term::InternalFun(_) => {
                return Err(crate::Error::Term("internal fun not supported".into()))
            }
            eetf::Term::ImproperList(list) => {
                // Convert improper list to regular list (losing tail)
                let elements: Result<Vec<_>, _> =
                    list.elements.iter().map(Term::from_eetf).collect();
                Term::List(elements?)
            }
        })
    }
}

impl ErlPid {
    pub fn new(node: &str, id: u32, serial: u32, creation: u32) -> ErlPid {
        ErlPid {
            node: node.to_string(),
            id,
            serial,
            creation,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_decode_atom() {
        let term = Term::atom("hello");
        let encoded = term.encode().unwrap();
        let decoded = Term::decode(&encoded).unwrap();
        assert_eq!(term, decoded);
    }

    #[test]
    fn test_encode_decode_tuple() {
        let term = Term::tuple(vec![
            Term::atom("hello"),
            Term::integer(42),
            Term::binary(b"world"),
        ]);
        let encoded = term.encode().unwrap();
        let decoded = Term::decode(&encoded).unwrap();
        assert_eq!(term, decoded);
    }
}
