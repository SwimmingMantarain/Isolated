#![allow(unused)] // shut up
#![allow(nonstandard_style)] // shut the fuck up

use sokol::{app as sapp, gfx as sg, glue as sglue, log as slog};
use std::collections::HashMap;
use std::ffi;

mod core_input;
mod core_render;
mod game;
mod generated_shader;
mod utils;

pub(crate) use generated_shader as gsh;

use crate::core_input::*;

#[derive(Clone)]
pub struct CoreContext {
    window_w: i32,
    window_h: i32,
    sprites: HashMap<game::SpriteKind, core_render::Sprite>,
    atlas: core_render::Atlas,
    font: core_render::Font,
}

#[derive(Clone)]
pub struct Context {
    core: CoreContext,
    render: core_render::RenderContext,
    input: core_input::InputContext,
}

fn main() {
    let mut ctx = Box::new(Context {
        core: CoreContext {
            window_w: game::WINDOW_W,
            window_h: game::WINDOW_H,
            sprites: HashMap::new(),
            atlas: core_render::Atlas {
                w: 0,
                h: 0,
                sg_image: sg::Image { id: 0 },
                sg_view: sg::View { id: 0 },
            },
            font: core_render::Font {
                char_data: unsafe { std::mem::zeroed() },
                sg_image: sg::Image { id: 0 },
                sg_view: sg::View { id: 0 },
            },
        },
        render: core_render::RenderContext {
            pa: sg::PassAction {
                ..Default::default()
            },
            pp: sg::Pipeline {
                ..Default::default()
            },
            bind: sg::Bindings {
                ..Default::default()
            },
            quad_data: unsafe { std::mem::zeroed() },
            timer: utils::Timer::new(),
            delta_t: 0.0,
            last_frame_time: 0.0,
            draw_frame: core_render::DrawFrame::default(),
        },
        input: core_input::InputContext {
            keys: unsafe { std::mem::zeroed() },
            mouse_x: 0.0,
            mouse_y: 0.0,
            scroll_x: 0.0,
            scroll_y: 0.0,
        },
    });

    let user_data = Box::into_raw(ctx) as *mut ffi::c_void;

    sapp::run(&sapp::Desc {
        init_userdata_cb: Some(core_init),
        frame_userdata_cb: Some(core_frame),
        cleanup_userdata_cb: Some(core_deinit),
        event_userdata_cb: Some(core_event),
        user_data: user_data,
        width: game::WINDOW_W,
        height: game::WINDOW_H,
        icon: sapp::IconDesc {
            sokol_default: true,
            ..sapp::IconDesc::default()
        },
        logger: sapp::Logger {
            func: Some(slog::slog_func),
            ..sapp::Logger::default()
        },
        ..sapp::Desc::default()
    });
}

extern "C" fn core_init(user_data: *mut ffi::c_void) {
    let mut ctx = get_state(user_data);

    core_render::init(ctx);
}

extern "C" fn core_frame(user_data: *mut ffi::c_void) {
    let mut ctx = get_state(user_data);

    let current_time = ctx.render.timer.secs_since_init();
    let mut frame_time = current_time - ctx.render.last_frame_time;
    ctx.render.last_frame_time = current_time;

    const MIN_FRAME_TIME: f64 = 1.0 / 20.0;
    if frame_time > MIN_FRAME_TIME {
        frame_time = MIN_FRAME_TIME;
    }

    ctx.render.delta_t = frame_time;

    // toggle fullscreen
    if key_pressed(ctx, KeyCode::ENTER) && key_down(ctx, KeyCode::LEFT_ALT) {
        sapp::toggle_fullscreen();
    }

    core_render::core_start_frame(ctx);
    game::frame(ctx);
    core_render::core_end_frame(ctx);
}

extern "C" fn core_deinit(user_data: *mut ffi::c_void) {
    let _ = unsafe { Box::from_raw(user_data as *mut Context) };
}

extern "C" fn core_event(e: *const sapp::Event, user_data: *mut ffi::c_void) {
    let mut ctx = get_state(user_data);

    core_input::event(e, ctx);
}

fn get_state<'a>(user_data: *mut ffi::c_void) -> &'a mut Context {
    return unsafe { &mut *(user_data as *mut Context) };
}
