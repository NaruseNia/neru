// Re-export primary types for clean API: neru.runtime.Event, neru.runtime.Response, etc.
pub const Event = event.Event;
pub const EventTag = event.EventTag;
pub const Response = event.Response;
pub const DirectiveArg = event.DirectiveArg;
pub const ChoiceOption = event.ChoiceOption;

// Sub-modules for detailed access
pub const event = @import("runtime/event.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
