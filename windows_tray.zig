const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
    @cInclude("shellapi.h");
    @cInclude("hidapi.h");
});

const VID: c_ushort = 0x1532;
const PIDS = [_]c_ushort{ 0x00B6, 0x00B7 };
const TRANSACTION_IDS = [_]u8{ 0x1f, 0x3f };
const REPORT_LEN = 90;
const WIRE_LEN = REPORT_LEN + 1;
const LOW_BATTERY_THRESHOLD: u8 = 20;
const WM_TRAYICON: c.UINT = c.WM_APP + 1;
const WM_TIMER_REFRESH: c.UINT_PTR = 1;
const IDM_REFRESH: c.UINT_PTR = 1001;
const IDM_EXIT: c.UINT_PTR = 1002;
const IDI_APPLICATION: c.LPCWSTR = @ptrFromInt(32512);

const Reading = struct {
    found: bool = false,
    level: u8 = 0,
    charging: bool = false,
    stale: bool = false,
    product: []const u8 = "Razer DeathAdder V3 Pro",
};

var last_reading = Reading{};
var last_success_at: u64 = 0;
var low_battery_notified = false;
var tray_icon: c.HICON = null;
var tray_icon_owned = false;

fn buildReport(transaction_id: u8, command: u8) [REPORT_LEN]u8 {
    var report = [_]u8{0} ** REPORT_LEN;
    report[0] = 0x00;
    report[1] = transaction_id;
    report[4] = 0x00;
    report[5] = 0x02;
    report[6] = 0x07;
    report[7] = command;
    var crc: u8 = 0;
    for (report[2..88]) |byte| crc ^= byte;
    report[88] = crc;
    return report;
}

fn readResponse(device: *c.hid_device, transaction_id: u8, command: u8) ?[REPORT_LEN]u8 {
    const payload = buildReport(transaction_id, command);
    var wire = [_]u8{0} ** WIRE_LEN;
    @memcpy(wire[1..], payload[0..]);
    if (c.hid_send_feature_report(device, &wire, WIRE_LEN) < 0) return null;

    _ = c.Sleep(60);
    const deadline = c.GetTickCount64() + 1000;
    while (c.GetTickCount64() < deadline) {
        var received = [_]u8{0} ** WIRE_LEN;
        const count = c.hid_get_feature_report(device, &received, WIRE_LEN);
        if (count < WIRE_LEN) return null;

        var response = [_]u8{0} ** REPORT_LEN;
        @memcpy(response[0..], received[1..]);
        var crc: u8 = 0;
        for (response[2..88]) |byte| crc ^= byte;
        if (crc != response[88]) return null;

        const is_expected_reply = response[1] == transaction_id and
            response[6] == 0x07 and response[7] == command;
        if (response[0] == 0x01 or (response[0] == 0x02 and !is_expected_reply)) {
            _ = c.Sleep(80);
            continue;
        }
        if (response[0] != 0x02 or !is_expected_reply) return null;
        return response;
    }
    return null;
}

fn readFromPath(path: [*:0]const u8, product: []const u8) ?Reading {
    const device = c.hid_open_path(path) orelse return null;
    defer c.hid_close(device);

    for (TRANSACTION_IDS) |transaction_id| {
        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            if (readResponse(device, transaction_id, 0x80)) |response| {
                const raw: u16 = response[9];
                const level: u8 = @intCast(@min((raw * 100) / 255, 100));
                var charging = false;
                if (readResponse(device, transaction_id, 0x84)) |charge_response| {
                    charging = charge_response[9] != 0;
                }
                return .{ .found = true, .level = level, .charging = charging, .product = product };
            }
            _ = c.Sleep(250);
        }
    }
    return null;
}

fn queryMouse() Reading {
    if (c.hid_init() != 0) return .{};
    defer _ = c.hid_exit();

    // First prefer MI_00 / Generic Desktop Mouse (usage page 0x01, usage 0x02).
    // The receiver exposes several collections; if one is claimed by Synapse
    // or does not answer, continue with every other matching collection.
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        var enumeration = c.hid_enumerate(VID, 0);
        defer c.hid_free_enumeration(enumeration);
        while (enumeration != null) : (enumeration = enumeration.*.next) {
            const info = enumeration.*;
            var supported_pid = false;
            for (PIDS) |pid| {
                if (info.product_id == pid) supported_pid = true;
            }
            if (!supported_pid) continue;
            const is_mouse_collection = info.usage_page == 0x01 and info.usage == 0x02;
            if ((pass == 0 and !is_mouse_collection) or (pass == 1 and is_mouse_collection)) continue;
            if (readFromPath(info.path, "Razer DeathAdder V3 Pro")) |reading| return reading;
        }
    }
    return .{};
}

fn wide(comptime text: []const u8) [text.len + 1]u16 {
    var result = [_]u16{0} ** (text.len + 1);
    for (text, 0..) |byte, index| result[index] = byte;
    return result;
}

fn setTip(nid: *c.NOTIFYICONDATAW, text: []const u8) void {
    @memset(&nid.szTip, 0);
    const limit = @min(text.len, nid.szTip.len - 1);
    for (text[0..limit], 0..) |byte, index| nid.szTip[index] = byte;
}

fn setWideText(buffer: []u16, text: []const u8) void {
    @memset(buffer, 0);
    const limit = @min(text.len, buffer.len - 1);
    for (text[0..limit], 0..) |byte, index| buffer[index] = byte;
}

fn setIconPixel(pixels: *[32 * 32]u32, x: usize, y: usize, color: u32) void {
    pixels[y * 32 + x] = color;
}

fn fillIconRect(pixels: *[32 * 32]u32, x1: usize, y1: usize, x2: usize, y2: usize, color: u32) void {
    var y = y1;
    while (y < y2) : (y += 1) {
        var x = x1;
        while (x < x2) : (x += 1) setIconPixel(pixels, x, y, color);
    }
}

fn batteryIconColor(reading: Reading) u32 {
    if (!reading.found or reading.stale) return 0xff888888;
    if (reading.charging) return 0xffe8c840;
    if (reading.level <= LOW_BATTERY_THRESHOLD) return 0xffe83030;
    if (reading.level <= 40) return 0xfff0b020;
    return 0xff50c840;
}

fn shouldNotifyLowBattery(reading: Reading, already_notified: bool) bool {
    return reading.found and !reading.stale and !reading.charging and reading.level <= LOW_BATTERY_THRESHOLD and !already_notified;
}

fn createBatteryIcon(reading: Reading) ?c.HICON {
    var bitmap_info: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bitmap_info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = 32;
    bitmap_info.bmiHeader.biHeight = -32;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = c.BI_RGB;

    var pixel_memory: ?*anyopaque = null;
    const color_bitmap = c.CreateDIBSection(null, &bitmap_info, c.DIB_RGB_COLORS, @ptrCast(&pixel_memory), null, 0) orelse return null;
    defer _ = c.DeleteObject(color_bitmap);
    const pixel_pointer = pixel_memory orelse return null;
    const pixels: *[32 * 32]u32 = @ptrCast(@alignCast(pixel_pointer));
    @memset(pixels, 0);

    const outline: u32 = 0xfff0f0f0;
    const background: u32 = 0xff202020;
    const fill_color = batteryIconColor(reading);

    fillIconRect(pixels, 12, 3, 20, 6, outline);
    fillIconRect(pixels, 6, 6, 26, 28, outline);
    fillIconRect(pixels, 8, 8, 24, 26, background);
    const fill_height: usize = (@as(usize, reading.level) * 16 + 99) / 100;
    if (fill_height > 0) fillIconRect(pixels, 9, 25 - fill_height, 23, 25, fill_color);

    if (reading.charging and !reading.stale) {
        fillIconRect(pixels, 16, 11, 19, 16, outline);
        fillIconRect(pixels, 13, 16, 17, 20, outline);
        fillIconRect(pixels, 11, 20, 15, 23, outline);
    }

    var mask = [_]u8{0} ** 128;
    const mask_bitmap = c.CreateBitmap(32, 32, 1, 1, &mask) orelse return null;
    defer _ = c.DeleteObject(mask_bitmap);
    var icon_info: c.ICONINFO = .{
        .fIcon = c.TRUE,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask_bitmap,
        .hbmColor = color_bitmap,
    };
    return c.CreateIconIndirect(&icon_info);
}

fn notifyLowBattery(hwnd: c.HWND, level: u8) void {
    var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = c.NIF_INFO;
    setWideText(&nid.szInfoTitle, "Razer DeathAdder V3 Pro");
    var message: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&message, "Low battery: {d}%. Connect the USB cable to charge.", .{level}) catch "Low battery. Connect the USB cable to charge.";
    setWideText(&nid.szInfo, text);
    nid.dwInfoFlags = c.NIIF_WARNING;
    _ = c.Shell_NotifyIconW(c.NIM_MODIFY, &nid);
}

fn updateTray(hwnd: c.HWND) void {
    const reading = queryMouse();
    if (reading.found) {
        last_reading = reading;
        last_success_at = c.GetTickCount64();
        if (reading.level > LOW_BATTERY_THRESHOLD or reading.charging) {
            low_battery_notified = false;
        } else if (shouldNotifyLowBattery(reading, low_battery_notified)) {
            notifyLowBattery(hwnd, reading.level);
            low_battery_notified = true;
        }
    } else if (last_reading.found and c.GetTickCount64() - last_success_at <= 300000) {
        last_reading.stale = true;
    } else {
        last_reading = .{};
    }
    const custom_icon = createBatteryIcon(last_reading);
    const new_icon = custom_icon orelse c.LoadIconW(null, IDI_APPLICATION);
    const previous_icon = tray_icon;
    const previous_icon_owned = tray_icon_owned;
    tray_icon = new_icon;
    tray_icon_owned = custom_icon != null;
    var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon = tray_icon;

    var tip: [256]u8 = undefined;
    const tip_text = if (!last_reading.found)
        "Razer DeathAdder V3 Pro: battery not found"
    else if (last_reading.stale)
        std.fmt.bufPrint(&tip, "Razer DeathAdder V3 Pro: {d}% (last seen)", .{last_reading.level}) catch "Razer battery"
    else if (last_reading.charging)
        std.fmt.bufPrint(&tip, "Razer DeathAdder V3 Pro: {d}% (charging)", .{last_reading.level}) catch "Razer battery"
    else
        std.fmt.bufPrint(&tip, "Razer DeathAdder V3 Pro: {d}%", .{last_reading.level}) catch "Razer battery";
    setTip(&nid, tip_text);
    if (c.Shell_NotifyIconW(c.NIM_MODIFY, &nid) != 0) {
        if (previous_icon_owned and previous_icon != null and previous_icon != new_icon) _ = c.DestroyIcon(previous_icon);
    } else {
        if (tray_icon_owned and tray_icon != null and tray_icon != previous_icon) _ = c.DestroyIcon(tray_icon);
        tray_icon = previous_icon;
        tray_icon_owned = previous_icon_owned;
    }
}

fn showMenu(hwnd: c.HWND) void {
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    const refresh = wide("Refresh now");
    const exit_text = wide("Exit");
    _ = c.AppendMenuW(menu, c.MF_STRING, IDM_REFRESH, &refresh);
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(menu, c.MF_STRING, IDM_EXIT, &exit_text);

    var point: c.POINT = undefined;
    _ = c.GetCursorPos(&point);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.TrackPopupMenu(menu, c.TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, null);
    _ = c.PostMessageW(hwnd, c.WM_NULL, 0, 0);
}

fn removeTray(hwnd: c.HWND) void {
    var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    _ = c.Shell_NotifyIconW(c.NIM_DELETE, &nid);
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_CREATE => {
            tray_icon = c.LoadIconW(null, IDI_APPLICATION);
            var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
            nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
            nid.hWnd = hwnd;
            nid.uID = 1;
            nid.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP;
            nid.uCallbackMessage = WM_TRAYICON;
            nid.hIcon = tray_icon;
            setWideText(&nid.szTip, "Razer DeathAdder V3 Pro");
            _ = c.Shell_NotifyIconW(c.NIM_ADD, &nid);
            _ = c.SetTimer(hwnd, WM_TIMER_REFRESH, 30000, null);
            updateTray(hwnd);
            return 0;
        },
        c.WM_TIMER => {
            if (wparam == WM_TIMER_REFRESH) updateTray(hwnd);
            return 0;
        },
        WM_TRAYICON => {
            if (lparam == c.WM_RBUTTONUP or lparam == c.WM_LBUTTONUP) showMenu(hwnd);
            return 0;
        },
        c.WM_COMMAND => {
            const command_id: c.UINT_PTR = @intCast(@as(c.ULONG_PTR, @bitCast(wparam)) & 0xffff);
            if (command_id == IDM_REFRESH) {
                updateTray(hwnd);
            } else if (command_id == IDM_EXIT) {
                _ = c.DestroyWindow(hwnd);
            }
            return 0;
        },
        c.WM_DESTROY => {
            removeTray(hwnd);
            _ = c.KillTimer(hwnd, WM_TIMER_REFRESH);
            if (tray_icon_owned and tray_icon != null) _ = c.DestroyIcon(tray_icon);
            c.PostQuitMessage(0);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

pub fn main() !void {
    const mutex_name = wide("Local\\RazerDeathAdderV3ProBatteryTray");
    const mutex = c.CreateMutexW(null, c.FALSE, &mutex_name) orelse return error.CreateMutexFailed;
    defer _ = c.CloseHandle(mutex);
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) return;

    const class_name = wide("RazerBatteryTrayWindow");
    const title = wide("Razer DeathAdder V3 Pro Battery");
    const instance = c.GetModuleHandleW(null);

    var window_class: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    window_class.cbSize = @sizeOf(c.WNDCLASSEXW);
    window_class.lpfnWndProc = windowProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = &class_name;
    if (c.RegisterClassExW(&window_class) == 0) return error.RegisterClassFailed;

    const hwnd = c.CreateWindowExW(
        0,
        &class_name,
        &title,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    _ = hwnd;

    var message: c.MSG = undefined;
    while (c.GetMessageW(&message, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
}

test "battery warning is sent once for fresh readings at or below 20 percent" {
    const low = Reading{ .found = true, .level = 20 };
    try std.testing.expect(shouldNotifyLowBattery(low, false));
    try std.testing.expect(!shouldNotifyLowBattery(low, true));
    try std.testing.expect(!shouldNotifyLowBattery(.{ .found = true, .level = 21 }, false));
    try std.testing.expect(!shouldNotifyLowBattery(.{ .found = true, .level = 10, .stale = true }, false));
    try std.testing.expect(!shouldNotifyLowBattery(.{ .found = true, .level = 10, .charging = true }, false));
    try std.testing.expect(!shouldNotifyLowBattery(.{ .level = 10 }, false));
}

test "battery status icon colors distinguish charge states" {
    try std.testing.expectEqual(@as(u32, 0xff50c840), batteryIconColor(.{ .found = true, .level = 75 }));
    try std.testing.expectEqual(@as(u32, 0xfff0b020), batteryIconColor(.{ .found = true, .level = 40 }));
    try std.testing.expectEqual(@as(u32, 0xffe83030), batteryIconColor(.{ .found = true, .level = 20 }));
    try std.testing.expectEqual(@as(u32, 0xffe8c840), batteryIconColor(.{ .found = true, .level = 80, .charging = true }));
    try std.testing.expectEqual(@as(u32, 0xff888888), batteryIconColor(.{ .found = true, .level = 80, .stale = true }));
}

test "battery icon can be created for the tray" {
    const icon = createBatteryIcon(.{ .found = true, .level = 20 }) orelse return error.IconCreationFailed;
    defer _ = c.DestroyIcon(icon);
}
