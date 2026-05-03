// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    {
        const release_step = b.step("release", "Build all of the release artifacts");

        const update = b.addUpdateSourceFiles();
        release_step.dependOn(&update.step);
        const optimize: std.builtin.OptimizeMode = .ReleaseSafe;
        const build_for = [_]std.Build.ResolvedTarget{
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .cpu_model = .baseline,
                .os_tag = .linux,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .cpu_model = .baseline,
                .os_tag = .windows,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .cpu_model = .baseline,
                .os_tag = .linux,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .cpu_model = .baseline,
                .os_tag = .macos,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .cpu_model = .baseline,
                .os_tag = .windows,
            }),
        };

        for (build_for) |target| {
            const exe = buildExe(b, target, optimize);
            const install_exe = b.addInstallArtifact(exe, .{});
            if (install_exe.emitted_bin) |bin| update.addCopyFileToSource(
                bin,
                b.fmt(
                    "hooks/pre-command-{t}-{t}{s}",
                    .{
                        target.result.cpu.arch,
                        target.result.os.tag,
                        if (target.result.os.tag == .windows) ".exe" else "",
                    },
                ),
            );
        }
    }

    {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        const exe = buildExe(b, target, optimize);

        b.installArtifact(exe);

        {
            const run_step = b.step("run", "Run the app");
            const run_cmd = b.addRunArtifact(exe);
            run_step.dependOn(&run_cmd.step);

            run_cmd.step.dependOn(b.getInstallStep());

            if (b.args) |args| {
                run_cmd.addArgs(args);
            }
        }

        {
            const exe_tests = b.addTest(.{
                .root_module = exe.root_module,
            });

            const run_exe_tests = b.addRunArtifact(exe_tests);

            const test_step = b.step("test", "Run tests");
            test_step.dependOn(&run_exe_tests.step);
        }
    }
}

pub fn buildExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const minizign_dep = b.dependency("minizign", .{
        .target = target,
        .optimize = optimize,
    });
    const win32_dep = b.dependency("win32", .{});
    const exe = b.addExecutable(.{
        .name = "pre-command",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "minizign",
                    .module = minizign_dep.module("minizign"),
                },
                .{
                    .name = "win32",
                    .module = win32_dep.module("win32"),
                },
            },
            .strip = switch (optimize) {
                .Debug => false,
                .ReleaseSafe, .ReleaseSmall, .ReleaseFast => true,
            },
        }),
    });
    return exe;
}
