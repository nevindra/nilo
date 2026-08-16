//! Asking a reading for a field the Config does not have. A typo here would
//! otherwise answer with empty text, which reads exactly like a setting
//! nobody supplied — the one answer that must never be a guess.

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read.given("prot");
}
