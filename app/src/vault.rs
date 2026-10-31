//! The key that seals MCP tokens on the desktop (ADR-0007 decision D-3).
//!
//! The backend encrypts the tokens of connected MCP services with `NODESTRO_VAULT_KEY` (32 random bytes, base64). The
//! key lives in the operating system's keychain (Secret Service on Linux, Keychain on macOS, Credential Manager on
//! Windows); the first start creates it. It is handed to the backend in its environment, never on the command line,
//! and never written to a file or a log.
//!
//! Without a usable keychain (no Secret Service running, access refused, a locked keychain that stays locked) the
//! backend gets no key and keeps tokens for the session only: there is no plain-text fallback. A key that was lost
//! from the keychain makes the stored tokens unreadable (the backend then asks for them again); it never reveals them.

/// The variable through which the backend receives the key (`nodestro_runtime.mcp.vault`).
pub const VAULT_KEY_ENV: &str = "NODESTRO_VAULT_KEY";
/// The keychain entry: service and account name.
const SERVICE: &str = "Nodestro";
const ACCOUNT: &str = "mcp-token-vault-key";
const KEY_BYTES: usize = 32;

/// Where the key is kept; the real one is the operating system's keychain, tests use memory.
pub trait KeyStore {
    /// The stored key; `Ok(None)` when there is none yet.
    fn load(&self) -> Result<Option<String>, String>;
    fn save(&self, key: &str) -> Result<(), String>;
}

/// The operating system's keychain.
pub struct SystemKeychain;

impl SystemKeychain {
    fn entry() -> Result<keyring::Entry, String> {
        keyring::Entry::new(SERVICE, ACCOUNT).map_err(|error| error.to_string())
    }
}

impl KeyStore for SystemKeychain {
    fn load(&self) -> Result<Option<String>, String> {
        match Self::entry()?.get_password() {
            Ok(key) => Ok(Some(key)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(error.to_string()),
        }
    }

    fn save(&self, key: &str) -> Result<(), String> {
        Self::entry()?.set_password(key).map_err(|error| error.to_string())
    }
}

/// Standard base64 with padding (what the backend decodes).
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for (index, shift) in [18u32, 12, 6, 0].into_iter().enumerate() {
            if index <= chunk.len() {
                out.push(char::from(ALPHABET[((n >> shift) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// A new key: 32 bytes from the operating system's generator, base64-encoded.
pub fn new_key() -> String {
    let mut bytes = [0u8; KEY_BYTES];
    getrandom::fill(&mut bytes).expect("the operating system's random number generator");
    base64(&bytes)
}

/// A stored key is used only when it looks like one of ours (at least 44 base64 characters); anything else is left
/// alone rather than overwritten, and the backend keeps tokens for the session.
fn plausible(key: &str) -> bool {
    key.len() >= 44 && key.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
}

/// The key from `store`, created on first use; `Err` with the reason when the keychain cannot be used.
///
/// A new key is read back after saving, so a keychain that accepts but does not keep entries is not trusted with
/// tokens that would be unreadable after the next start.
pub fn vault_key(store: &dyn KeyStore) -> Result<String, String> {
    if let Some(key) = store.load()? {
        return if plausible(&key) { Ok(key) } else { Err("the keychain entry is not a Nodestro key".into()) };
    }
    let key = new_key();
    store.save(&key)?;
    match store.load()? {
        Some(kept) if kept == key => Ok(key),
        _ => Err("the keychain did not keep the new key".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default)]
    struct Memory {
        value: RefCell<Option<String>>,
        forgetful: bool,
        broken: bool,
    }

    impl KeyStore for Memory {
        fn load(&self) -> Result<Option<String>, String> {
            if self.broken {
                return Err("no Secret Service".into());
            }
            Ok(self.value.borrow().clone())
        }
        fn save(&self, key: &str) -> Result<(), String> {
            if !self.forgetful {
                *self.value.borrow_mut() = Some(key.to_string());
            }
            Ok(())
        }
    }

    #[test]
    fn base64_matches_the_standard_encoding() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64(&[0xff; 32]), "//////////////////////////////////////////8=");
    }

    #[test]
    fn keys_are_32_random_bytes() {
        let (one, two) = (new_key(), new_key());
        assert_eq!(one.len(), 44);
        assert!(plausible(&one));
        assert_ne!(one, two);
    }

    #[test]
    fn the_first_start_creates_the_key_and_later_starts_reuse_it() {
        let store = Memory::default();
        let key = vault_key(&store).unwrap();
        assert_eq!(store.value.borrow().as_deref(), Some(key.as_str()));
        assert_eq!(vault_key(&store).unwrap(), key);
    }

    #[test]
    fn without_a_usable_keychain_there_is_no_key() {
        let broken = Memory { broken: true, ..Memory::default() };
        assert!(vault_key(&broken).is_err());
        let forgetful = Memory { forgetful: true, ..Memory::default() };
        assert!(vault_key(&forgetful).is_err());
        let foreign = Memory { value: RefCell::new(Some("hunter2".into())), ..Memory::default() };
        assert!(vault_key(&foreign).is_err());
        // A foreign entry is never overwritten.
        assert_eq!(foreign.value.borrow().as_deref(), Some("hunter2"));
    }

    /// Against the real keychain of this session; CI runs it in a D-Bus session with an unlocked gnome-keyring
    /// (`cargo test -- --ignored`). Reported as ignored, never as passed, where no Secret Service runs.
    #[test]
    #[ignore = "needs an unlocked Secret Service (CI: dbus-run-session + gnome-keyring)"]
    fn the_system_keychain_keeps_the_key() {
        let key = vault_key(&SystemKeychain).expect("a usable keychain");
        assert!(plausible(&key));
        assert_eq!(vault_key(&SystemKeychain).unwrap(), key);
        assert_eq!(SystemKeychain.load().unwrap().as_deref(), Some(key.as_str()));
        SystemKeychain::entry().unwrap().delete_credential().unwrap();
        assert_eq!(SystemKeychain.load().unwrap(), None);
    }
}
