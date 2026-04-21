use std::io;
use std::time::Duration;

use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use disktui_lite::app::{App, AppResult};
use disktui_lite::handler::{handle_key_events, poll_dd_progress};
#[cfg(target_os = "linux")]
use disktui_lite::init;
use disktui_lite::tui::Tui;
use disktui_lite::ui;

fn main() -> AppResult<()> {
    // Self-fork: if invoked with --dd, run as dd subprocess and exit.
    // This gives us process isolation for uu_dd: we can kill it with
    // Child::kill() and read progress via /proc/$PID/io.
    if std::env::args().any(|a| a == "--dd") {
        let dd_args: Vec<std::ffi::OsString> = std::iter::once(std::ffi::OsString::from("dd"))
            .chain(std::env::args_os().skip(2)) // skip argv[0] and --dd
            .collect();
        let code = uu_dd::uumain(dd_args.into_iter());
        std::process::exit(code);
    }

    // Detect if we are PID 1 (running as init in initramfs)
    #[cfg(target_os = "linux")]
    if std::process::id() == 1 {
        if let Err(e) = init::run_init() {
            init::emergency_shell(&format!("Init failed: {}", e));
        }
    }

    // Ignore SIGINT: we handle abort via UI (Esc), not Ctrl+C.
    #[cfg(unix)]
    {
        use nix::sys::signal::{SigHandler, Signal};
        unsafe {
            nix::sys::signal::signal(Signal::SIGINT, SigHandler::SigIgn)?;
        }
    }

    let backend = CrosstermBackend::new(io::stdout());
    let terminal = Terminal::new(backend)?;
    let mut tui = Tui::new(terminal);
    tui.init()?;

    let mut app = match App::new() {
        Ok(app) => app,
        Err(e) => {
            // Restore terminal before printing error
            drop(tui);
            eprintln!("Failed to initialize: {}", e);
            eprintln!("Dropping to shell.");
            let _ = std::process::Command::new("/bin/sh").status();
            return Ok(());
        }
    };

    while app.running {
        tui.draw(|frame| ui::render(&mut app, frame))?;

        // Poll dd progress
        poll_dd_progress(&mut app);

        // Handle input (100ms timeout = tick rate)
        if crossterm::event::poll(Duration::from_millis(100))? {
            if let crossterm::event::Event::Key(key) = crossterm::event::read()? {
                if key.kind == crossterm::event::KeyEventKind::Press {
                    let _ = handle_key_events(key, &mut app);
                }
            }
        }

        app.tick();
    }

    tui.exit()?;

    // After TUI exits, drop to shell (like installer.sh's "0. Shell" option).
    let _ = std::process::Command::new("/bin/sh").status();

    Ok(())
}
