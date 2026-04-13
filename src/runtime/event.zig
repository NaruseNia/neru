const std = @import("std");
const value_mod = @import("../vm/value.zig");

const Value = value_mod.Value;

pub const EventTag = enum {
    text_display,
    speaker_change,
    bg_change,
    sprite_show,
    sprite_hide,
    bgm_play,
    bgm_stop,
    se_play,
    transition,
    choice_prompt,
    wait,
    save_point,
};

pub const TextDisplay = struct {
    speaker: ?[]const u8,
    text: []const u8,
};

pub const SpeakerChange = struct {
    speaker: ?[]const u8,
};

pub const DirectiveArg = struct {
    key: []const u8,
    value: Value,
};

pub const BgChange = struct {
    image: []const u8,
    args: []const DirectiveArg,
};

pub const SpriteShow = struct {
    character: []const u8,
    args: []const DirectiveArg,
};

pub const SpriteHide = struct {
    character: []const u8,
    args: []const DirectiveArg,
};

pub const BgmPlay = struct {
    track: []const u8,
    args: []const DirectiveArg,
};

pub const SePlay = struct {
    sound: []const u8,
    args: []const DirectiveArg,
};

pub const Transition = struct {
    kind: []const u8,
    args: []const DirectiveArg,
};

pub const ChoiceOption = struct {
    label: []const u8,
    target: []const u8,
};

pub const ChoicePrompt = struct {
    options: []const ChoiceOption,
};

pub const Wait = struct {
    ms: u32,
};

pub const SavePoint = struct {
    name: []const u8,
};

pub const Event = union(EventTag) {
    text_display: TextDisplay,
    speaker_change: SpeakerChange,
    bg_change: BgChange,
    sprite_show: SpriteShow,
    sprite_hide: SpriteHide,
    bgm_play: BgmPlay,
    bgm_stop: void,
    se_play: SePlay,
    transition: Transition,
    choice_prompt: ChoicePrompt,
    wait: Wait,
    save_point: SavePoint,
};

pub const Response = union(enum) {
    none: void,
    text_ack: void,
    wait_completed: void,
    choice_selected: u32,
};

test "Event union covers all tags" {
    const e = Event{ .wait = .{ .ms = 100 } };
    try std.testing.expectEqual(EventTag.wait, @as(EventTag, e));
}

test "Response union basic construction" {
    const r1 = Response{ .text_ack = {} };
    try std.testing.expect(r1 == .text_ack);

    const r2 = Response{ .choice_selected = 2 };
    try std.testing.expectEqual(@as(u32, 2), r2.choice_selected);
}
