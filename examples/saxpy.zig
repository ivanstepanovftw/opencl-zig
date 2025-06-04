const std = @import("std");
const Allocator = std.mem.Allocator;

const cl = @import("opencl");

pub const std_options = .{
    .log_level = .info,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const Options = struct {
    platform: ?[]const u8,
    device: ?[]const u8,

    fn parse(a: Allocator) !Options {
        var args = try std.process.argsWithAllocator(a);
        _ = args.next(); // executable name

        var platform: ?[]const u8 = null;
        var device: ?[]const u8 = null;
        var help: bool = false;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--platform") or std.mem.eql(u8, arg, "-p")) {
                platform = args.next() orelse fail("missing argument to option {s}", .{arg});
            } else if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) {
                device = args.next() orelse fail("missing argument to option {s}", .{arg});
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                help = true;
            } else {
                fail("unknown option '{s}'", .{arg});
            }
        }

        if (help) {
            const out = std.io.getStdOut();
            try out.writer().writeAll(
                \\usage: saxpy [options...]
                \\
                \\Options:
                \\--platform|-p <platform>  OpenCL platform name to use. By default, uses the
                \\                          first platform that has any devices available.
                \\--device|-d <device>      OpenCL device name to use. If --platform is left
                \\                          unspecified, all devices of all platforms are
                \\                          matched. By default, uses the first device of the
                \\                          platform.
            );
            std.process.exit(0);
        }

        return .{
            .platform = platform,
            .device = device,
        };
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const options = try Options.parse(alloc);

    const platforms = try cl.getPlatforms(alloc);
    std.log.info("{} opencl platform(s) available", .{platforms.len});
    if (platforms.len == 0) {
        fail("no opencl platforms available", .{});
    }

    const platform, const device = found: for (platforms) |platform| {
        const platform_name = try platform.getName(alloc);
        if (options.platform) |platform_query| {
            if (std.mem.indexOf(u8, platform_name, platform_query) == null) {
                continue;
            }
        }

        const devices = try platform.getDevices(alloc, cl.DeviceType.all);
        for (devices) |device| {
            const device_name = try device.getName(alloc);
            if (options.device) |device_query| {
                if (std.mem.indexOf(u8, device_name, device_query) == null) {
                    continue;
                }
            }

            std.log.info("selected platform '{s}' and device '{s}'", .{ platform_name, device_name });

            break :found .{ platform, device };
        }
    } else {
        fail("failed to select platform and device", .{});
    };

    const context = try cl.createContext(&.{device}, .{ .platform = platform });
    defer context.release();

    const queue = try cl.createCommandQueue(context, device, .{ .profiling = true });
    defer queue.release();

    std.log.info("compiling kernel...", .{});

    const source =
        \\kernel void saxpy(global float* y, global const float* x, const float a) {
        \\    const size_t gid = get_global_id(0);
        \\    y[gid] += x[gid] * a;
        \\}
        \\
    ;

    const program = try cl.createProgramWithSource(context, source);
    defer program.release();

    program.build(
        &.{device},
        "-cl-std=CL3.0",
    ) catch |err| {
        if (err == error.BuildProgramFailure) {
            const log = try program.getBuildLog(alloc, device);
            defer alloc.free(log);
            std.log.err("failed to compile kernel:\n{s}", .{log});
        }

        return err;
    };

    const kernel = try cl.createKernel(program, "saxpy");
    defer kernel.release();

    std.log.info("generating inputs...", .{});

    const size = 1 * 1024 * 1024;
    const y, const x = blk: {
        const y = try alloc.alloc(f32, size);
        const x = try alloc.alloc(f32, size);
        var rng = std.Random.DefaultPrng.init(0);
        const random = rng.random();
        for (x) |*value| value.* = random.float(f32);
        for (y) |*value| value.* = random.float(f32);
        break :blk .{ y, x };
    };

    const results = try alloc.alloc(f32, size);

    const a: f32 = 10;

    const d_y = try cl.svmAlloc(f32, context, .{ .read_write = true, .fine_grain_buffer = true }, size, 0);
    defer cl.svmFree(context, d_y.ptr);
    const d_x = try cl.svmAlloc(f32, context, .{ .read_only = true, .fine_grain_buffer = true }, size, 0);
    defer cl.svmFree(context, d_x.ptr);
    std.mem.copy(f32, d_y[0..size], y);
    std.mem.copy(f32, d_x[0..size], x);

    std.log.info("launching kernel...", .{});

    try cl.setKernelArgSVMPointer(kernel, 0, d_y.ptr);
    try cl.setKernelArgSVMPointer(kernel, 1, d_x.ptr);
    try kernel.setArg(f32, 2, a);

    const saxpy_complete = try queue.enqueueNDRangeKernel(
        kernel,
        null,
        &.{size},
        &.{256},
        &.{},
    );
    defer saxpy_complete.release();

    try cl.waitForEvents(&.{saxpy_complete});
    std.mem.copy(f32, results, d_y[0..size]);

    std.log.info("checking results...", .{});

    // Compute reference results on host
    for (y, x) |*yi, xi| {
        yi.* += xi * a;
    }

    // Check if the results are close.
    // y = y + a * x is 2 operations of 0.5 ulp each,
    // multiply by 2 for host and device side error.
    const max_error = std.math.floatEps(f32) * 2 * 2;
    for (results, y, 0..) |ri, yi, i| {
        if (!std.math.approxEqRel(f32, ri, yi, max_error)) {
            fail("invalid result at index {}: expected = {d}, actual = {d}", .{ i, yi, ri });
        }
    }

    std.log.info("ok", .{});
}
