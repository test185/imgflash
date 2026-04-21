use ratatui::style::Color;

#[derive(Debug, Clone)]
pub struct Theme {
    pub focus_border: Color,
    pub normal_border: Color,
    pub highlight_bg: Color,
    pub highlight_fg: Color,
    pub header: Color,
    pub error: Color,
    pub warning: Color,
    pub success: Color,

    pub disk_name_width: u16,
    pub disk_size_width: u16,
    pub disk_type_width: u16,
    pub disk_model_width: u16,

    pub progress_bar_width: u8,
    pub progress_bar_filled: &'static str,
    pub progress_bar_empty: &'static str,
}

impl Default for Theme {
    fn default() -> Self {
        Self {
            focus_border: Color::Indexed(2),  // green
            normal_border: Color::Reset,
            highlight_bg: Color::Indexed(8),   // dark gray
            highlight_fg: Color::Reset,
            header: Color::Indexed(3),         // yellow
            error: Color::Indexed(1),          // red
            warning: Color::Indexed(3),        // yellow
            success: Color::Indexed(2),        // green

            disk_name_width: 14,
            disk_size_width: 12,
            disk_type_width: 10,
            disk_model_width: 30,

            progress_bar_width: 40,
            progress_bar_filled: "█",
            progress_bar_empty: "░",
        }
    }
}

impl Theme {
    pub fn new() -> Self {
        Self::default()
    }
}
