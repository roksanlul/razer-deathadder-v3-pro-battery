const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
    @cInclude("hidapi.h");
});

const REPORT_LEN = 90;
const WIRE_LEN = 91;

fn report(transaction_id: u8, command: u8) [REPORT_LEN]u8 {
    var result = [_]u8{0} ** REPORT_LEN;
    result[1] = transaction_id;
    result[5] = 0x02;
    result[6] = 0x07;
    result[7] = command;
    var crc: u8 = 0;
    for (result[2..88]) |byte| crc ^= byte;
    result[88] = crc;
    return result;
}

fn tryPath(path: [*:0]const u8, tid: u8, command: u8) void {
    const device = c.hid_open_path(path) orelse {
        std.debug.print("  open: FAILED\n", .{});
        return;
    };
    defer c.hid_close(device);
    const payload = report(tid, command);
    var outgoing = [_]u8{0} ** WIRE_LEN;
    @memcpy(outgoing[1..], payload[0..]);
    const written = c.hid_send_feature_report(device, &outgoing, WIRE_LEN);
    if (written < 0) {
        std.debug.print("  tid=0x{x}: write FAILED\n", .{tid});
        return;
    }
    _ = c.Sleep(60);
    var attempt: u8 = 0;
    while (attempt < 12) : (attempt += 1) {
        var incoming = [_]u8{0} ** WIRE_LEN;
        const count = c.hid_get_feature_report(device, &incoming, WIRE_LEN);
        if (count < WIRE_LEN) {
            std.debug.print("  tid=0x{x}: write={d}, read={d}\n", .{ tid, written, count });
            return;
        }
        const response = incoming[1..][0..REPORT_LEN];
        var crc: u8 = 0;
        for (response[2..88]) |byte| crc ^= byte;
        std.debug.print("  cmd=0x{x} tid=0x{x}: write={d}, read={d}, status=0x{x}, reply_tid=0x{x}, response=0x{x}:0x{x}, raw={d}, crc={s}\n", .{
            command,
            tid,
            written,
            count,
            response[0],
            response[1],
            response[6],
            response[7],
            response[9],
            if (crc == response[88]) "ok" else "BAD",
        });
        if (response[0] != 0x01) return;
        _ = c.Sleep(80);
    }
}

pub fn main() !void {
    if (c.hid_init() != 0) return error.HidInitFailed;
    defer _ = c.hid_exit();
    var item = c.hid_enumerate(0x1532, 0);
    defer c.hid_free_enumeration(item);
    var found: usize = 0;
    while (item != null) : (item = item.*.next) {
        const info = item.*;
        if (info.product_id != 0x00B6 and info.product_id != 0x00B7) continue;
        found += 1;
        const path = std.mem.span(info.path);
        std.debug.print("PID=0x{x:0>4} iface={d} usage_page=0x{x:0>4} usage=0x{x:0>4} path={s}\n", .{
            info.product_id, info.interface_number, info.usage_page, info.usage, path,
        });
        tryPath(info.path, 0x1f, 0x80);
        tryPath(info.path, 0x1f, 0x84);
        tryPath(info.path, 0x3f, 0x80);
        tryPath(info.path, 0x3f, 0x84);
    }
    if (found == 0) std.debug.print("No PID 00B6/00B7 HID entries found.\n", .{});
}
