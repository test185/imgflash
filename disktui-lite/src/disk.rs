use std::fs;
use std::path::Path;

use crate::utils::format_bytes;

/// Information about a single block device, obtained via /sys/block.
#[derive(Debug, Clone)]
pub struct DiskInfo {
    pub name: String,       // e.g. "sda"
    pub size_bytes: u64,    // total size in bytes
    pub model: String,
    pub is_readonly: bool,
    pub is_mounted: bool,
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

            if let Some(disk) = Self::from_sys_block(&name) {
                if !disk.is_readonly {
                    disks.push(disk);
                }
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

        let model = fs::read_to_string(base.join("device/model"))
            .or_else(|_| fs::read_to_string(base.join("device/name")))
            .unwrap_or_else(|_| "Unknown".to_string())
            .trim()
            .to_string();

        let is_mounted = Self::check_mounted(name);

        Some(Self {
            name: name.to_string(),
            size_bytes,
            model,
            is_readonly,
            is_mounted,
        })
    }

    /// Check if the device or any of its partitions are mounted (via /proc/mounts).
    fn check_mounted(name: &str) -> bool {
        if let Ok(mounts) = fs::read_to_string("/proc/mounts") {
            for line in mounts.lines() {
                if line.starts_with(&format!("/dev/{}", name)) {
                    return true;
                }
            }
        }
        false
    }

    pub fn size_str(&self) -> String {
        format_bytes(self.size_bytes)
    }

    pub fn device_type(&self) -> &str {
        match &self.name {
            n if n.starts_with("nvme") => "NVMe",
            n if n.starts_with("sd") => "SSD/HDD",
            n if n.starts_with("vd") => "VirtIO",
            n if n.starts_with("mmcblk") => "eMMC",
            n if n.starts_with("hd") => "IDE",
            _ => "Disk",
        }
    }

    pub fn dev_path(&self) -> String {
        format!("/dev/{}", self.name)
    }
}
