//! The numbers an operator would want to change without a rebuild.
//!
//! Registered as a service and asked for as a **`*const Settings`**, which is a
//! different type from `*Settings` and is looked up as such — a read-only
//! service saying so in the only place that cannot drift, the signature
//! (ADR 0006).
//!
//! M2 fills this in from the environment with `nilo_config` instead of the
//! defaults below, and no handler changes.

pub const Settings = struct {
    /// How big an attachment may be. Under `listen()`'s `max_body`, because a
    /// form is read whole into the request arena before a handler sees it.
    attachment_bytes: usize = 512 * 1024,

    /// How much a bulk import may send. Far over `max_body`, and legitimately
    /// so: the import reads its body in pieces and holds one line at a time.
    import_bytes: usize = 32 * 1024 * 1024,

    /// How much work the reindex pretends to be, in thousands of spins. High
    /// enough that a handler which forgets `nilo.blocking` trips the watchdog,
    /// whose default is a quarter of a second.
    reindex_rounds: u32 = 800_000,
};
