use anyhow::Context;

use crate::app::{App, ConfirmButton, Screen, SuccessAction, WriteProgress};

pub fn handle_key_events(key: crossterm::event::KeyEvent, app: &mut App) -> anyhow::Result<()> {
    use crossterm::event::{KeyCode, KeyModifiers};

    // Global hotkeys (any screen)
    if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
        app.quit();
        return Ok(());
    }

    if app.show_help {
        app.show_help = false;
        return Ok(());
    }

    match app.screen {
        Screen::DiskList => handle_disk_list(key, app),
        Screen::Confirmation => handle_confirmation(key, app),
        Screen::Writing => handle_writing(key, app),
        Screen::WriteError => handle_write_error(key, app),
        Screen::ResizePrompt => handle_resize_prompt(key, app),
        Screen::Success => handle_success(key, app),
    }
}

// ── Disk list ───────────────────────────────────────────────────────────

fn handle_disk_list(key: crossterm::event::KeyEvent, app: &mut App) -> anyhow::Result<()> {
    use crossterm::event::KeyCode;

    match key.code {
        KeyCode::Char('q') => {
            app.quit();
        }
        KeyCode::Char('?') => {
            app.show_help = true;
        }
        KeyCode::Char('r') => {
            if let Err(e) = app.refresh_disks() {
                app.notify(format!("Failed to refresh: {}", e), crate::notification::NotificationLevel::Error);
            } else {
                app.notify("Disk list refreshed", crate::notification::NotificationLevel::Info);
            }
        }
        KeyCode::Down | KeyCode::Char('j') => {
            if !app.disks.is_empty() {
                let i = app.disks_state.selected().unwrap_or(0);
                let next = (i + 1).min(app.disks.len() - 1);
                app.disks_state.select(Some(next));
            }
        }
        KeyCode::Up | KeyCode::Char('k') => {
            if !app.disks.is_empty() {
                let i = app.disks_state.selected().unwrap_or(0);
                let prev = i.saturating_sub(1);
                app.disks_state.select(Some(prev));
            }
        }
        KeyCode::Enter => {
            try_select_disk(app);
        }
        _ => {}
    }
    Ok(())
}

fn try_select_disk(app: &mut App) {
    let disk = match app.selected_disk() {
        Some(d) => d.clone(),
        None => return,
    };

    if disk.is_mounted {
        app.notify(
            format!("/dev/{} is currently mounted!", disk.name),
            crate::notification::NotificationLevel::Error,
        );
        return;
    }

    if !app.image_exists() {
        app.notify(
            "Image file not found at /image/image.img",
            crate::notification::NotificationLevel::Error,
        );
        return;
    }

    if let Some(img_size) = app.image_file_size()
        && disk.size_bytes < img_size
    {
        app.notify(
            "Disk is smaller than the image! Write will fail.",
            crate::notification::NotificationLevel::Error,
        );
        return;
    }

    app.goto_confirmation();
}

// ── Confirmation ────────────────────────────────────────────────────────

fn handle_confirmation(key: crossterm::event::KeyEvent, app: &mut App) -> anyhow::Result<()> {
    use crossterm::event::KeyCode;

    match key.code {
        KeyCode::Left | KeyCode::Char('h') => {
            app.confirm_button = ConfirmButton::No;
        }
        KeyCode::Right | KeyCode::Char('l') => {
            app.confirm_button = ConfirmButton::Yes;
        }
        KeyCode::Tab => {
            app.confirm_button.toggle();
        }
        KeyCode::Enter => {
            if app.confirm_button == ConfirmButton::Yes {
                if let Err(e) = start_write(app) {
                    app.notify(format!("Failed to start write: {}", e), crate::notification::NotificationLevel::Error);
                    app.goto_disk_list();
                }
            } else {
                app.goto_disk_list();
            }
        }
        _ => {}
    }
    Ok(())
}

// ── Writing (progress) ──────────────────────────────────────────────────

fn handle_writing(key: crossterm::event::KeyEvent, app: &mut App) -> anyhow::Result<()> {
    use crossterm::event::KeyCode;

    match key.code {
        KeyCode::Esc | KeyCode::Char('a') => {
            abort_write(app);
        }
        _ => {}
    }
    Ok(())
}

// ── Write error ─────────────────────────────────────────────────────────

fn handle_write_error(key: crossterm::event::KeyEvent, app: &mut App) -> anyhow::Result<()> {
    use crossterm::event::KeyCode;

    match key.code {
        KeyCode::Enter | KeyCode::Esc => {
            app.goto_disk_list();
        }
        _ => {}
    }
    Ok(())
}

// ── Success (reboot countdown) ──────────────────────────────────────────

fn handle_success(key: crossterm::event::KeyEvent, app: &mut App) -> anyhow::Result<()> {
    use crossterm::event::KeyCode;

    match key.code {
        KeyCode::Left | KeyCode::Char('h') | KeyCode::Right | KeyCode::Char('l') | KeyCode::Tab => {
            if !app.reboot_counting {
                app.success_action.toggle();
            }
        }
        KeyCode::Enter => {
            if !app.reboot_counting {
                match app.success_action {
                    SuccessAction::Reboot => {
                        app.reboot_counting = true;
                        app.reboot_last_tick = app.tick_count;
                    }
                    SuccessAction::Back => {
                        app.goto_disk_list();
                    }
                }
            } else {
                app.skip_reboot_countdown();
            }
        }
        _ => {}
    }
    Ok(())
}

// ── Start dd write ──────────────────────────────────────────────────────
//
// We spawn ourselves with --dd flag, which makes the child process
// invoke uu_dd::uumain() and exit. This gives us process isolation:
// - Child::kill() can truly abort the write
// - /proc/$PID/io gives clean per-process wchar for progress tracking

fn start_write(app: &mut App) -> anyhow::Result<()> {
    let disk = match app.selected_disk() {
        Some(d) => d.clone(),
        None => return Ok(()),
    };

    let img_bytes = app.image_file_size()
        .context("Failed to get image file size")?;

    let child = std::process::Command::new("/proc/self/exe")
        .arg("--dd")
        .arg(format!("if={}", App::IMAGE_FILE))
        .arg(format!("of=/dev/{}", disk.name))
        .arg("bs=4M")
        .arg("conv=fsync")
        .arg("status=none")
        .spawn()
        .context("Failed to spawn dd process")?;

    let progress = WriteProgress::new(&disk, img_bytes, child);

    let sectors: u64 = std::fs::read_to_string(format!("/sys/block/{}/size", disk.name))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);

    app.goto_writing(progress, disk.name, sectors);

    Ok(())
}

/// Abort write: kill the dd child process and return to disk list.
fn abort_write(app: &mut App) {
    if let Some(ref mut p) = app.progress {
        p.abort();
        app.notify("Write operation aborted.", crate::notification::NotificationLevel::Warning);
    }
    app.goto_disk_list();
}

// ── Poll dd progress (called every tick) ────────────────────────────────

pub fn poll_dd_progress(app: &mut App) {
    if app.screen != Screen::Writing {
        return;
    }

    let progress = match app.progress.as_mut() {
        Some(p) => p,
        None => return,
    };

    if progress.finished {
        return;
    }

    let (process_status, written) = progress.check_and_read_io();
    progress.update_progress(written, 0.1);

    match process_status {
        Some(true) => {
            app.goto_resize_prompt();
        }
        Some(false) => {
            app.goto_write_error();
        }
        None => {}
    }
}

// ── Resize prompt ──────────────────────────────────────────────────────

fn handle_resize_prompt(key: crossterm::event::KeyEvent, app: &mut App) -> anyhow::Result<()> {
    use crossterm::event::KeyCode;

    match key.code {
        KeyCode::Left | KeyCode::Char('h') => {
            app.confirm_button = ConfirmButton::No;
        }
        KeyCode::Right | KeyCode::Char('l') => {
            app.confirm_button = ConfirmButton::Yes;
        }
        KeyCode::Tab => {
            app.confirm_button.toggle();
        }
        KeyCode::Enter => {
            if app.confirm_button == ConfirmButton::Yes {
                do_resize(app);
            }
            app.goto_success();
        }
        _ => {}
    }
    Ok(())
}

fn do_resize(app: &mut App) {
    let dev = format!("/dev/{}", app.written_disk_name);

    // Get last partition number
    let sg_out = match std::process::Command::new("/sbin/sgdisk")
        .args(["-p", &dev])
        .output()
    {
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
        Err(e) => {
            app.notify(format!("sgdisk failed: {}", e), crate::notification::NotificationLevel::Error);
            return;
        }
    };
    let part = match sg_out.lines()
        .filter_map(|line| line.split_whitespace().next()?.parse::<u32>().ok())
        .last()
    {
        Some(p) => p,
        None => {
            app.notify("No partitions found, cannot resize.", crate::notification::NotificationLevel::Error);
            return;
        }
    };

    // Fix GPT backup header
    if let Err(e) = std::process::Command::new("/sbin/sgdisk")
        .args(["-g", &dev])
        .output()
    {
        app.notify(format!("GPT repair failed: {}", e), crate::notification::NotificationLevel::Error);
        return;
    }

    // Expand partition
    if let Err(e) = std::process::Command::new("/sbin/sgdisk")
        .args(["-d", &part.to_string(), "-N", &part.to_string(), &dev])
        .output()
    {
        app.notify(format!("Partition expansion failed: {}", e), crate::notification::NotificationLevel::Error);
        return;
    }

    // Notify kernel
    let _ = std::process::Command::new("partprobe")
        .arg(&dev)
        .output();
    std::thread::sleep(std::time::Duration::from_secs(1));

    // Determine partition device path (probe both naming conventions)
    let part_dev_p = format!("{}p{}", dev, part);
    let part_dev_n = format!("{}{}", dev, part);
    let part_dev = if std::path::Path::new(&part_dev_p).exists() {
        part_dev_p
    } else {
        part_dev_n
    };
    if let Ok(blkid) = std::process::Command::new("blkid")
        .args(["-o", "value", "-s", "TYPE", &part_dev])
        .output()
    {
        let fstype = String::from_utf8_lossy(&blkid.stdout).trim().to_string();
        match fstype.as_str() {
            "ext4" => { let _ = std::process::Command::new("resize2fs").arg(&part_dev).output(); }
            "xfs"  => { let _ = std::process::Command::new("xfs_growfs").arg(&part_dev).output(); }
            _ => {}
        }
    }

    // Flush all pending writes to disk
    let _ = std::process::Command::new("sync").output();

    app.notify("Partition expanded!", crate::notification::NotificationLevel::Info);
}
