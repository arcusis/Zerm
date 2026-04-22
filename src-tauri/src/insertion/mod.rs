//! Text insertion planning primitives.
//!
//! This module intentionally does not call native APIs. It describes how the
//! pipeline should decide between direct accessibility insertion, clipboard
//! paste fallbacks, copy-only recovery, and platform-specific strategies.

mod strategy;

pub use strategy::*;
