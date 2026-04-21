use std::fs;
use std::path::Path;

use crate::utils::format_bytes;

/// Information about a single block device, obtained via /sys/block.
#[derive(Debug, Clone)]
pub struct DiskInfo {
    pub name: String,       // e.g. "sda"
    pub size_bytes: u64,    // total size in bytes
    pub vendor: String,
    pub model: String,
    pub bus: String,        // SATA, USB, NVMe, VirtIO, eMMC
    pub disk_type: String,  // SSD, HDD
    pub is_fixed: bool,     // true = fixed, false = removable
    pub is_readonly: bool,
    pub is_mounted: bool,
    pub mount_point: Option<String>,
}

impl DiskInfo {
    /// Enumerate writable disks via /sys/block (same logic as installer.sh).
    pub fn enumerate() -> anyhow::Result<Vec<Self>> {
        let mut disks = Vec::new();
        let sys_block = Path::new("/sys/block");

        if !sys_block.is_dir() {
            return Ok(disks);
        }

        let prefixes = ["sd", "nvme", "vd", "hd", "mmcblk"];

        for entry in fs::read_dir(sys_block)? {
            let entry = entry?;
            let name_os = entry.file_name();
            let name = name_os.to_string_lossy().to_string();

            if !prefixes.iter().any(|p| name.starts_with(p)) {
                continue;
            }

            if let Some(disk) = Self::from_sys_block(&name)
                && !disk.is_readonly
            {
                disks.push(disk);
            }
        }

        disks.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(disks)
    }

    fn from_sys_block(name: &str) -> Option<Self> {
        let base = Path::new("/sys/block").join(name);
        if !base.is_dir() {
            return None;
        }

        let ro = fs::read_to_string(base.join("ro"))
            .unwrap_or_else(|_| "1".to_string())
            .trim()
            .to_string();
        let is_readonly = ro != "0";

        let sectors: u64 = fs::read_to_string(base.join("size"))
            .unwrap_or_else(|_| "0".to_string())
            .trim()
            .parse()
            .unwrap_or(0);
        let size_bytes = sectors * 512;

        let vendor = fs::read_to_string(base.join("device/vendor"))
            .or_else(|_| fs::read_to_string(base.join("device/device/vendor")))
            .unwrap_or_else(|_| "Unknown".to_string())
            .trim()
            .to_string();

        let model = fs::read_to_string(base.join("device/model"))
            .or_else(|_| fs::read_to_string(base.join("device/device/model")))
            .or_else(|_| fs::read_to_string(base.join("device/name")))
            .or_else(|_| fs::read_to_string(base.join("device/device/name")))
            .unwrap_or_else(|_| "Unknown".to_string())
            .trim()
            .to_string();

        let removable: u8 = fs::read_to_string(base.join("removable"))
            .unwrap_or_else(|_| "0".to_string())
            .trim()
            .parse()
            .unwrap_or(0);
        let is_fixed = removable == 0;

        let (is_mounted, mount_point) = Self::check_mounted(name);

        let bus = Self::detect_bus(name);
        let disk_type = Self::detect_disk_type(&base);

        Some(Self {
            name: name.to_string(),
            size_bytes,
            vendor,
            model,
            bus,
            disk_type,
            is_fixed,
            is_readonly,
            is_mounted,
            mount_point,
        })
    }

    fn detect_disk_type(base: &Path) -> String {
        let rotational: u8 = fs::read_to_string(base.join("queue/rotational"))
            .unwrap_or_else(|_| "0".to_string())
            .trim()
            .parse()
            .unwrap_or(0);
        if rotational == 0 { "SSD".to_string() } else { "HDD".to_string() }
    }

    fn detect_bus(name: &str) -> String {
        if name.starts_with("nvme") {
            "NVMe".to_string()
        } else if name.starts_with("vd") {
            "VirtIO".to_string()
        } else if name.starts_with("mmcblk") {
            "eMMC".to_string()
        } else if name.starts_with("hd") {
            "IDE".to_string()
        } else if name.starts_with("sd") {
            Self::detect_sd_bus(name)
        } else {
            "Unknown".to_string()
        }
    }

    fn detect_sd_bus(name: &str) -> String {
        let base = Path::new("/sys/block").join(name);

        if let Ok(link) = fs::read_link(base.join("device/subsystem")) {
            let subsystem = link
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default();
            match subsystem.as_str() {
                "usb" => return "USB".to_string(),
                "scsi" => {}
                _ => return subsystem,
            }
        }

        if let Ok(link) = fs::read_link(base.join("device")) {
            let path = link.to_string_lossy().to_string();
            if path.contains("/usb") {
                return "USB".to_string();
            }
        }

        if let Ok(removable) = fs::read_to_string(base.join("removable"))
            && removable.trim() == "1"
        {
            return "USB".to_string();
        }

        "SCSI/SATA".to_string()
    }

    /// Check if the device or any of its partitions are mounted (via /proc/mounts).
    fn check_mounted(name: &str) -> (bool, Option<String>) {
        if name.trim().is_empty() {
            return (false, None);
        }

        if let Ok(mounts) = fs::read_to_string("/proc/mounts") {
            for line in mounts.lines() {
                let mut parts = line.split_whitespace();
                if let (Some(dev_path), Some(mount_point)) = (parts.next(), parts.next())
                    && let Some(dev_name) = dev_path.strip_prefix("/dev/")
                {
                    let is_match = if dev_name == name {
                        true
                    } else if let Some(suffix) = dev_name.strip_prefix(name) {
                        let first_char = suffix.chars().next().unwrap_or(' ');
                        first_char.is_ascii_digit() || first_char == 'p'
                    } else {
                        false
                    };

                    if is_match {
                        return (true, Some(mount_point.to_string()));
                    }
                }
            }
        }
        (false, None)
    }

    pub fn size_str(&self) -> String {
        format_bytes(self.size_bytes)
    }

    pub fn dev_path(&self) -> String {
        format!("/dev/{}", self.name)
    }

    pub fn fixed_str(&self) -> &'static str {
        if self.is_fixed { "fixed" } else { "removable" }
    }

    pub fn mounted_str(&self) -> String {
        if self.is_mounted {
            if let Some(ref mp) = self.mount_point {
                format!("mounted ({})", mp)
            } else {
                "mounted".to_string()
            }
        } else {
            "unmounted".to_string()
        }
    }
}