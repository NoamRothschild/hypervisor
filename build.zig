const std = @import("std");

/// Adds a NASM file to the build and returns the path to the compiled object file
fn addNasmFile(b: *std.Build, kernel: *std.Build.Step.Compile, source_path: []const u8, name: []const u8) void {
    const output_path = b.fmt("zig-out/bin/{s}.o", .{name});

    const nasm_command = b.addSystemCommand(&[_][]const u8{
        "nasm",
        "-f",
        "elf64",
        "-o",
        output_path,
        source_path,
    });

    kernel.root_module.addObjectFile(b.path(output_path));
    kernel.step.dependOn(&nasm_command.step);
}

pub fn build(b: *std.Build) void {
    const wf = b.addWriteFiles();
    var disabled_features: std.Target.Cpu.Feature.Set = .empty;
    var enabled_features: std.Target.Cpu.Feature.Set = .empty;

    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.mmx));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.sse));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.sse2));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
    enabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.soft_float));

    const target_query = std.Target.Query{
        .cpu_arch = std.Target.Cpu.Arch.x86_64,
        .os_tag = std.Target.Os.Tag.freestanding,
        .abi = std.Target.Abi.none,
        .cpu_features_sub = disabled_features,
        .cpu_features_add = enabled_features,
    };

    const optimize = b.standardOptimizeOption(.{});
    const default_step = b.getInstallStep();
    const target = b.resolveTargetQuery(target_query);

    const root_file = "src/main.zig";
    const linker_script = "src/linker.ld";
    const out_iso = "zig-out/kernel.iso";

    // Create kernel executable
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_file),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
        }),
    });
    // Linker-script symbols require LLVM + LLD.
    kernel.use_llvm = true;
    kernel.use_lld = true;

    const assembly_files = [_]struct { []const u8, []const u8 }{
        .{ "src/arch/x86_64/entry.asm", "entry" },
        .{ "src/arch/x86_64/interrupts.asm", "interrupts" },
    };

    for (assembly_files) |pair|
        addNasmFile(b, kernel, pair[0], pair[1]);

    kernel.setLinkerScript(b.path(linker_script));
    b.installArtifact(kernel);

    // creating a temp system folder, placing all neccesities there
    _ = wf.addCopyFile(kernel.getEmittedBin(), "tmpsys/kernel/boot/kernel.elf");

    // Copy GRUB configuration to bootloader location
    _ = wf.addCopyFile(b.path("src/grub.cfg"), "tmpsys/kernel/boot/grub/grub.cfg");

    // taking the temp system directory and copying into the global system dir its contents
    const copy_built_system = b.addInstallDirectory(.{
        .source_dir = wf.getDirectory().path(b, "tmpsys/kernel"),
        .install_dir = .{ .custom = "sysroot/kernel" },
        .install_subdir = "",
    });
    copy_built_system.step.dependOn(&kernel.step);

    const makeiso = b.addSystemCommand(&[_][]const u8{ "grub-mkrescue", "-o", out_iso, "zig-out/sysroot/kernel/" });
    makeiso.step.dependOn(&copy_built_system.step);

    const compile_steps = [_]*std.Build.Step{ &kernel.step, &copy_built_system.step, &makeiso.step };
    for (compile_steps) |step| {
        default_step.dependOn(step);
    }

    {
        const run_qemu = b.addSystemCommand(&[_][]const u8{ "qemu-system-x86_64", "-cdrom", out_iso, "-serial", "stdio", "-enable-kvm", "-cpu", "host,vmx=on" });
        const qemu_step = b.step("run", "compile & launch qemu");

        qemu_step.dependOn(default_step);
        for (compile_steps) |step| {
            run_qemu.step.dependOn(step);
        }
        qemu_step.dependOn(&run_qemu.step);
    }

    {
        const run_qemu = b.addSystemCommand(&[_][]const u8{ "qemu-system-x86_64", "-cdrom", out_iso, "-s", "-S", "-serial", "stdio", "-enable-kvm", "-cpu", "host,vmx=on" });
        const qemu_step = b.step("debug", "compile & launch qemu with a debugger");

        qemu_step.dependOn(default_step);
        for (compile_steps) |step| {
            run_qemu.step.dependOn(step);
        }
        qemu_step.dependOn(&run_qemu.step);
    }
}
