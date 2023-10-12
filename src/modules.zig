pub const Process = @import("modules/Process.zig");
pub const Timeout = @import("modules/Timeout.zig");
pub const ToUpper = @import("modules/ToUpper.zig");

test {
    _ = @import("std").testing.refAllDecls(@This());
}
