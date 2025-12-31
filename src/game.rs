use crate::Context;
use bitflags::bitflags;
use strum_macros::{EnumIter, FromRepr};

pub const VERSION: &str = "v0.0.0";
pub const WINDOW_TITLE: &str = "Isolated";
pub const GAME_RES_WIDTH: i32 = 480;
pub const GAME_RES_HEIGHT: i32 = 270;
pub const WINDOW_W: i32 = 1280;
pub const WINDOW_H: i32 = 720;

#[derive(EnumIter, FromRepr, Debug, PartialEq, Eq, Copy, Clone, Hash)]
#[repr(i32)]
pub enum SpriteKind {
    nil = 0,
    test = 1,
}

#[derive(EnumIter, FromRepr, Debug, PartialEq, Eq, Copy, Clone, Hash)]
#[repr(u32)]
pub enum ZLayer {
    nil = 0,
    bg = 1,
    shadow = 2,
    playspace = 3,
    toptile = 4,
    vfx = 5,
    ui = 6,
    tooltip = 7,
    pause_menu = 8,
    top = 9,
}

bitflags! {
    #[derive(Clone)]
    #[repr(transparent)]
    pub struct QuadFlags: u8 {
        const BACKGROUND_PIXELS = 1 << 0;
        const FLAG2             = 1 << 1;
        const FLAG3             = 1 << 2;
    }
}

pub fn frame(ctx: &mut Context) {}
