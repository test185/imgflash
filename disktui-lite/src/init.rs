/// Init phase: replaces scripts/init.sh
///
/// This code only runs on Linux (initramfs). It is gated behind
/// `is_pid1` detection in main.rs, but must still compile on the
/// build host (which may be Windows/macOS during cross-compilation setup).

#[cfg(target_os = "linux")]
use std::fs;
#[cfg(target_os = "linux")]
use std::path::Path;

#[cfg(target_os = "linux")]
use anyhow::{bail, Context};

// ── Public API ──────────────────────────────────────────────────────────

/// Run the init phase. Returns Ok(()) if everything is set up.
#[cfg(target_os = "linux")]
pub fn run_init() -> anyhow::Result<()> {
    eprintln!("ImgFlash init starting...");

    install_busybox()?;
    setup_path();
    mount_virtual_fs()?;
    parse_cmdline()?;
    load_modules()?;
    scan_and_mount_boot_media()?;
    verify_image()?;

    eprintln!("Init complete. Starting installer...");
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn run_init() -> anyhow::Result<()> {
    anyhow::bail!("Init is only supported on Linux")
}

/// Drop to emergency shell with a message.
pub fn emergency_shell(msg: &str) -> ! {
    eprintln!("ERROR: {}", msg);
    eprintln!("Dropping to emergency shell.");
    let _ = std::process::Command::new("/bin/sh").status();
    std::process::exit(1);
}

// ── Implementation (Linux only) ─────────────────────────────────────────

/// Install busybox symlinks (MUST be first — no other commands exist yet).
#[cfg(target_os = "linux")]
fn install_busybox() -> anyhow::Result<()> {
    let status = std::process::Command::new("/bin/busybox")
        .arg("--install")
        .arg("-s")
        .status()
        .context("Failed to run busybox --install -s")?;
    if !status.success() {
        bail!("busybox --install -s failed with exit code {:?}", status.code());
    }
    Ok(())
}

/// Set up PATH so that modprobe, mount, etc. are discoverable.
#[cfg(target_os = "linux")]
fn setup_path() {
    unsafe {
        std::env::set_var("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    }
}

#[cfg(target_os = "linux")]
fn mount_virtual_fs() -> anyhow::Result<()> {
    // Create mount points
    for dir in &["/proc", "/sys", "/dev", "/run", "/tmp", "/media/cdrom", "/image",
                 "/dev/pts", "/dev/shm", "/etc", "/root", "/var/log"] {
        let _ = fs::create_dir_all(dir);
    }

    use nix::mount::MsFlags;

    // proc
    mount_fs("proc", "/proc", "proc",
             MsFlags::MS_NOEXEC | MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
             None)?;

    // sysfs
    mount_fs("sysfs", "/sys", "sysfs",
             MsFlags::MS_NOEXEC | MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
             None)?;

    // devtmpfs with fallback to tmpfs
    mount_fs("devtmpfs", "/dev", "devtmpfs",
             MsFlags::MS_NOSUID,
             Some("mode=0755"))
        .or_else(|_| {
            eprintln!("devtmpfs unavailable, falling back to tmpfs");
            mount_fs("tmpfs", "/dev", "tmpfs",
                     MsFlags::MS_NOSUID,
                     Some("mode=0755"))
        })?;

    // devpts
    fs::create_dir_all("/dev/pts").ok();
    mount_fs("devpts", "/dev/pts", "devpts",
             MsFlags::MS_NOEXEC | MsFlags::MS_NOSUID,
             Some("gid=5,mode=0620"))?;

    // shm
    fs::create_dir_all("/dev/shm").ok();
    mount_fs("shm", "/dev/shm", "tmpfs",
             MsFlags::MS_NODEV | MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC,
             None)?;

    // Ensure essential device nodes
    use nix::sys::stat::{Mode, SFlag, mknod};

    if !Path::new("/dev/null").exists() {
        let _ = mknod("/dev/null", SFlag::S_IFCHR, Mode::from_bits(0o666).unwrap(), nix::sys::stat::makedev(1, 3));
    }
    if !Path::new("/dev/kmsg").exists() {
        let _ = mknod("/dev/kmsg", SFlag::S_IFCHR, Mode::from_bits(0o660).unwrap(), nix::sys::stat::makedev(1, 11));
    }

    // /etc/mtab -> /proc/mounts symlink
    #[cfg(unix)]
    {
        let _ = std::os::unix::fs::symlink("/proc/mounts", "/etc/mtab");
    }

    Ok(())
}

#[cfg(target_os = "linux")]
fn mount_fs(source: &str, target: &str, fstype: &str, flags: nix::mount::MsFlags, data: Option<&str>) -> anyhow::Result<()> {
    nix::mount::mount(Some(source), target, Some(fstype), flags, data)
        .or_else(|e| {
            // If already mounted (EBUSY), that's fine
            match e {
                nix::errno::Errno::EBUSY => Ok(()),
                _ => Err(e),
            }
        })
        .map_err(|e| anyhow::anyhow!("mount {} on {} (type {}): {}", source, target, fstype, e))
}

#[cfg(target_os = "linux")]
fn parse_cmdline() -> anyhow::Result<()> {
    if let Ok(cmdline) = fs::read_to_string("/proc/cmdline") {
        for opt in cmdline.split_whitespace() {
            match opt {
                "quiet" => {
                    // Suppress kernel messages to console
                    let _ = fs::write("/proc/sys/kernel/printk", "1\n");
                }
                "debug" => {
                    #[allow(unsafe_code)]
                    unsafe {
                        std::env::set_var("DEBUG", "1");
                    }
                }
                _ => {}
            }
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn load_modules() -> anyhow::Result<()> {
    let modules_path = "/etc/modules";
    if !Path::new(modules_path).exists() {
        return Ok(());
    }

    eprintln!("Loading kernel modules...");

    let content = fs::read_to_string(modules_path)
        .context("Failed to read /etc/modules")?;

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // modprobe silently ignores failures (same as init.sh)
        let _ = std::process::Command::new("modprobe")
            .arg(line)
            .status();
    }

    Ok(())
}

/// Scan block devices for ISO9660 containing image.squashfs.
#[cfg(target_os = "linux")]
fn scan_and_mount_boot_media() -> anyhow::Result<()> {
    // Wait for block devices to settle
    eprintln!("Scanning for boot media...");
    std::thread::sleep(std::time::Duration::from_secs(2));

    let scan_timeout = get_scan_timeout();
    let mut tries = 0;

    while tries < scan_timeout {
        for dev in enumerate_block_devices() {
            if try_mount_boot_device(&dev) {
                eprintln!("Boot media found: {}", dev);
                return Ok(());
            }
        }
        tries += 1;
        std::thread::sleep(std::time::Duration::from_secs(1));
    }

    bail!("Boot media not found after {} seconds", scan_timeout);
}

#[cfg(target_os = "linux")]
fn get_scan_timeout() -> u64 {
    std::env::var("SCAN_TIMEOUT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(10)
}

/// Enumerate block devices to scan, in priority order.
#[cfg(target_os = "linux")]
fn enumerate_block_devices() -> Vec<String> {
    let mut devices = Vec::new();
    let prefixes = ["sr", "sd", "nvme", "vd"];

    if let Ok(entries) = fs::read_dir("/dev") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if prefixes.iter().any(|p| name.starts_with(p)) {
                devices.push(format!("/dev/{}", name));
            }
        }
    }

    // Sort: sr* (optical) first, then sd*, nvme*, vd*
    devices.sort_by(|a, b| {
        let a_prio = device_priority(a);
        let b_prio = device_priority(b);
        b_prio.cmp(&a_prio).then(a.cmp(b))
    });

    devices
}

#[cfg(target_os = "linux")]
fn device_priority(dev: &str) -> u8 {
    if dev.contains("sr") { 4 }
    else if dev.contains("sd") { 3 }
    else if dev.contains("nvme") { 2 }
    else if dev.contains("vd") { 1 }
    else { 0 }
}

/// Try to mount a device as ISO9660 and check for image.squashfs.
#[cfg(target_os = "linux")]
fn try_mount_boot_device(device: &str) -> bool {
    use nix::mount::{MsFlags, mount, umount};

    // Try mounting as ISO9660 read-only
    if mount(Some(device), "/media/cdrom", Some("iso9660"), MsFlags::MS_RDONLY, None::<&str>).is_ok() {
        if Path::new("/media/cdrom/image.squashfs").exists() {
            // Found boot media! Mount squashfs.
            if mount_squashfs() {
                return true;
            }
            let _ = umount("/media/cdrom");
        } else {
            let _ = umount("/media/cdrom");
        }
    }
    false
}

/// Mount the squashfs image. Uses external `mount -o loop` because
/// loop device setup requires complex ioctl handling that isn't worth
/// reimplementing in pure Rust.
#[cfg(target_os = "linux")]
fn mount_squashfs() -> bool {
    std::process::Command::new("mount")
        .args(["-t", "squashfs", "-o", "ro,loop", "/media/cdrom/image.squashfs", "/image"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(target_os = "linux")]
fn verify_image() -> anyhow::Result<()> {
    if !Path::new("/image/image.img").exists() {
        bail!("image.img not found in squashfs");
    }
    Ok(())
}